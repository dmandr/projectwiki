require 'base64'
require 'timeout'

module Gollum
  # Reads committed regular blobs only. PDF extraction does not depend on RAG.
  module ProjectbookAttachments
    Error = ProjectbookCreation::Error
    MAX_ATTACHMENT = 100 * 1024 * 1024
    MAX_RESOURCE = 16 * 1024 * 1024
    MAX_PDF_OUTPUT = 16 * 1024 * 1024

    def attachment!(path)
      path!(path)
      entry = entries.find { |e| e[:path] == path && visible?(e) && !markdown?(e) }
      raise Error.new('Attachment not found.', 404) unless entry
      raise Error, 'Attachment exceeds the 100 MiB limit.' if entry[:bytes] > MAX_ATTACHMENT
      entry
    end

    def attachment_uri(entry)
      "projectbook://attachments/#{revision}/#{Base64.urlsafe_encode64(entry[:path], padding: false)}"
    end

    def attachment_mime(entry)
      {'.pdf' => 'application/pdf', '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg',
       '.gif' => 'image/gif', '.webp' => 'image/webp', '.txt' => 'text/plain'}.fetch(::File.extname(entry[:path]).downcase, 'application/octet-stream')
    end

    def with_attachment(entry)
      Tempfile.create(['projectbook-attachment', '.bin']) do |file|
        file.binmode
        ok = system({'GIT_OPTIONAL_LOCKS' => '0'}, 'git', '-C', @wiki.path, 'cat-file', 'blob', entry[:sha], out: file, err: ::File::NULL)
        raise Error, 'Could not read attachment.' unless ok
        file.flush
        raise Error, 'Attachment size mismatch.' unless file.size == entry[:bytes]
        file.rewind
        yield file
      end
    end

    def read_attachment(path:, format: 'resource', offset: 0, length: 65536)
      entry = attachment!(path)
      metadata = entry.merge(revision: revision, mime_type: attachment_mime(entry), uri: attachment_uri(entry),
        resource_limit_bytes: MAX_RESOURCE)
      if format == 'resource'
        raise Error, 'Use format=bytes for byte ranges.' unless offset == 0
        metadata.merge(resource_link: {type: 'resource_link', uri: attachment_uri(entry), name: ::File.basename(path),
          mimeType: attachment_mime(entry), size: entry[:bytes],
          description: 'Original committed file. Use resources/read; over 16 MiB use read_attachment(format=bytes) and follow next_offset with this revision.'})
      elsif format == 'bytes'
        raise Error, 'Use offset >= 0 and length 1..98304.' unless offset.is_a?(Integer) && offset >= 0 && length.is_a?(Integer) && (1..98304).cover?(length)
        raise Error, 'Offset exceeds file size.' if offset > entry[:bytes]
        with_attachment(entry) do |file|
          file.seek(offset); data = file.read(length) || ''.b
          metadata.merge(encoding: 'base64', data: Base64.strict_encode64(data), offset: offset, returned_bytes: data.bytesize,
            next_offset: offset + data.bytesize < entry[:bytes] ? offset + data.bytesize : nil)
        end
      else
        raise Error, 'Use format resource or bytes.'
      end
    end

    def attachment_resource(path)
      entry = attachment!(path)
      raise Error, 'File exceeds the 16 MiB resource limit. Use read_attachment with format=bytes and this revision.' if entry[:bytes] > MAX_RESOURCE
      with_attachment(entry) do |file|
        {uri: attachment_uri(entry), mimeType: attachment_mime(entry), blob: Base64.strict_encode64(file.read)}
      end
    end

    # Resource limits apply to the child, not the web process. Never invoke a shell.
    def pdf_command(*args, output:)
      pid = Process.spawn({'LC_ALL' => 'C'}, *args, out: output, err: ::File::NULL,
        rlimit_as: 1024 * 1024 * 1024, rlimit_cpu: 25, rlimit_fsize: MAX_PDF_OUTPUT)
      begin
        _, status = Timeout.timeout(30) { Process.wait2(pid) }
        raise Error, 'PDF extraction failed (invalid, encrypted, or extraction limit exceeded). Try a smaller page range or retrieve the original file.' unless status.success?
      rescue Timeout::Error
        Process.kill('KILL', pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
        raise Error, 'PDF extraction timed out. Try a smaller page range or retrieve the original file.'
      end
    rescue Errno::ENOENT
      raise Error.new('PDF extraction is not installed in this deployment.', 503)
    end

    def read_pdf_text(path:, start_page: 1, end_page: nil, page_offset: 0, max_chars: 40000)
      entry = attachment!(path)
      raise Error, 'Use a PDF attachment path.' unless path.match?(/\.pdf\z/i)
      raise Error, 'Invalid page range or text budget.' unless start_page.is_a?(Integer) && start_page >= 1 &&
        (end_page.nil? || end_page.is_a?(Integer) && end_page >= start_page) && page_offset.is_a?(Integer) && page_offset >= 0 &&
        max_chars.is_a?(Integer) && (1..40000).cover?(max_chars)
      with_attachment(entry) do |pdf|
        Tempfile.create('projectbook-pdf-info') do |info|
          pdf_command('pdfinfo', pdf.path, output: info)
          info.rewind; page_count = info.read[/^Pages:\s+(\d+)/, 1].to_i
          raise Error, 'Invalid PDF or page count exceeds 3000.' unless (1..3000).cover?(page_count)
          last = end_page || page_count
          raise Error, "Page range exceeds PDF length (#{page_count})." if start_page > page_count || last > page_count
          # Bound work per request; whole-document reads continue at next_page.
          batch_last = [last, start_page + 49].min
          Tempfile.create('projectbook-pdf-text') do |output|
            pdf_command('pdftotext', '-layout', '-enc', 'UTF-8', '-f', start_page.to_s, '-l', batch_last.to_s, pdf.path, '-', output: output)
            output.rewind; raw = output.read.force_encoding(Encoding::UTF_8).scrub
            texts = raw.split("\f", -1)
            texts.pop if texts.last == ''
            raise Error, 'PDF page boundaries could not be preserved.' unless texts.length == batch_last - start_page + 1
            pages = []; remaining = max_chars; next_page = batch_last < last ? batch_last + 1 : nil; next_offset = 0
            texts.each_with_index do |text, index|
              number = start_page + index; offset = index.zero? ? page_offset : 0
              raise Error, 'page_offset exceeds page text length.' if offset > text.length
              part = text[offset, remaining] || ''
              pages << {page: number, text: part, offset: offset, page_characters: text.length, empty: text.strip.empty?}
              remaining -= part.length
              if offset + part.length < text.length
                next_page = number; next_offset = offset + part.length; break
              elsif remaining.zero? && number < last
                next_page = number + 1; break
              end
            end
            entry.merge(revision: revision, total_pages: page_count, requested_start_page: start_page, requested_end_page: last,
              pages: pages, complete: next_page.nil?, next_page: next_page, next_page_offset: next_page && next_offset,
              extractor: 'poppler', ocr: false, guidance: 'Text only; scans may have no text and table layout may be imperfect. Continue with next_page, next_page_offset and the same revision/end_page. Original file is available through read_attachment.')
          end
        end
      end
    end
  end
end
