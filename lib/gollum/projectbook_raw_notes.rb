require 'base64'
require 'fileutils'
require 'tmpdir'
require 'ipaddr'
require 'resolv'

module Gollum
  module ProjectbookRawNotes
    Error = ProjectbookCreation::Error
    MAX_FILE = 20 * 1024 * 1024
    MAX_TOTAL = 50 * 1024 * 1024
    UUID = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/
    TYPES = {'image/jpeg'=>'jpg','image/png'=>'png','image/webp'=>'webp','image/heic'=>'heic','image/heif'=>'heif','audio/mp4'=>'m4a','audio/mpeg'=>'mp3','audio/webm'=>'webm','audio/ogg'=>'ogg','audio/wav'=>'wav','audio/x-wav'=>'wav'}.freeze
    def self.id!(id)
      raise Error, 'Use a UUID request/file ID.' unless id.is_a?(String) && UUID.match?(id)
      id
    end
    def self.stage(wiki)
      root = ENV.fetch('PROJECTBOOK_RAW_UPLOADS', '/tmp/projectbook-raw-uploads')
      dir = ::File.join(root, Digest::SHA256.hexdigest(wiki.path)[0,20])
      FileUtils.mkdir_p(dir, mode: 0700)
      Dir.glob(::File.join(dir, '*')).each { |f| FileUtils.rm_f(f) if ::File.file?(f) && ::File.mtime(f) < Time.now - 86400 }
      dir
    end
    def self.upload(wiki, upload_id:, offset:, data:)
      raise Error.new('Editing is disabled.',403) unless wiki.allow_editing
      id!(upload_id)
      raise Error, 'Invalid chunk offset.' unless offset.is_a?(Integer) && offset >= 0 && offset <= MAX_FILE
      begin
        bytes = Base64.strict_decode64(data)
      rescue ArgumentError, TypeError
        raise Error, 'Invalid base64 chunk.'
      end
      raise Error, 'Chunk must contain 1..262144 bytes.' unless (1..262144).cover?(bytes.bytesize)
      raise Error, 'Attachment exceeds 20 MiB.' if offset + bytes.bytesize > MAX_FILE
      root = stage(wiki)
      raise Error, 'Upload staging is full. Retry after old drafts expire.' if Dir.glob(root+'/*').sum { |f| ::File.size(f) } + bytes.bytesize > 250 * 1024 * 1024
      path = ::File.join(root,upload_id)
      ::File.open(path, ::File.exist?(path) ? 'r+b' : 'w+b', 0600) do |file|
        raise Error.new('Upload offset mismatch.',409) if offset > file.size
        file.seek(offset)
        if offset < file.size
          raise Error.new('Retry chunk differs from stored bytes.',409) unless file.read(bytes.bytesize) == bytes
        else
          file.write(bytes)
        end
        {upload_id: upload_id, next_offset: offset + bytes.bytesize}
      end
    end
    # Resolve and pin the connection address, including every redirect. Never
    # fetch private infrastructure through an agent-supplied attachment URL.
    def self.download(wiki, file)
      uri = URI(file.fetch('download_url',''))
      bytes = nil; type = nil
      4.times do
        raise Error, 'Attachment URL must use public HTTPS without credentials.' unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && uri.port == 443
        addresses = Resolv.getaddresses(uri.host)
        blocked = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 192.0.0.0/24 192.0.2.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32].map { |s| IPAddr.new(s) }
        raise Error, 'Attachment host is not a public address.' if addresses.empty? || addresses.any? { |s| ip=IPAddr.new(s); ip.ipv4_mapped? || blocked.any? { |range| range.include?(ip) } }
        http = Net::HTTP.new(uri.host,443,nil); http.ipaddr = addresses.first; http.use_ssl = true; http.open_timeout=10; http.read_timeout=20
        redirect = nil
        http.start do |connection|
          connection.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
            if response.is_a?(Net::HTTPRedirection)
              redirect = URI.join(uri.to_s,response.fetch('location')); next
            end
            raise Error, 'Could not download the attachment.' unless response.is_a?(Net::HTTPSuccess)
            type = response['content-type'].to_s.split(';').first
            type = file['mime_type'].to_s.split(';').first if type == 'application/octet-stream' || type.empty?
            raise Error, 'Only photos and audio can be downloaded.' unless TYPES.key?(type)
            raise Error, 'Attachment exceeds 20 MiB.' if response['content-length'].to_i > MAX_FILE
            bytes = ''.b
            response.read_body { |chunk| bytes << chunk; raise Error, 'Attachment exceeds 20 MiB.' if bytes.bytesize > MAX_FILE }
          end
        end
        if redirect; uri=redirect; else; break; end
      end
      raise Error, 'Too many attachment redirects or empty file.' unless bytes && !bytes.empty?
      upload_id = SecureRandom.uuid
      bytes.bytes.each_slice(262144).with_index { |slice,i| upload(wiki,upload_id:upload_id,offset:i*262144,data:Base64.strict_encode64(slice.pack('C*'))) }
      {'upload_id'=>upload_id,'name'=>file.fetch('file_name','attachment'),'mime_type'=>type,'sha256'=>Digest::SHA256.hexdigest(bytes)}
    rescue URI::InvalidURIError, Resolv::ResolvError, SocketError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error, 'Attachment download failed. Ask for the file again or retry.'
    end
    def self.catalog(snapshot)
      snapshot.entries.filter_map do |entry|
        next unless entry[:path].match?(%r{\Araw-notes/[^/]+/\.note.json\z})
        meta = JSON.parse(snapshot.text(entry))
        path = entry[:path].sub('.note.json','note.md')
        doc = snapshot.entries.find { |e| e[:path] == path }
        next unless doc
        meta.merge('path'=>path,'url'=>snapshot.url(path),'version'=>entry[:sha], 'document_version'=>doc[:sha], 'title'=>ProjectbookTitles.title(snapshot.text(doc),path), 'excerpt'=>snapshot.text(doc).sub(/\A# [^\n]*\n/, '').gsub(/!?\[([^\]]*)\]\([^)]*\)/) { $1.start_with?('photo-', 'voice-') ? '' : $1 }.gsub(/\s+/, ' ').strip[0,280])
      end.sort_by { |item| Time.iso8601(item['created_at']) }.reverse
    end
    def self.create(wiki, input, options)
      raise Error.new('Editing is disabled.',403) unless wiki.allow_editing
      id = id!(input['id'])
      title, text = input.fetch('title','').strip, input.fetch('text','')
      raise Error, 'Title must be at most 200 characters on one line.' if title.length > 200 || title.match?(/[\x00-\x1f]/)
      raise Error, 'Text must be at most 100000 characters.' unless text.is_a?(String) && text.length <= 100000
      files = input.fetch('attachments',[])
      raise Error, 'At most 20 attachments per note.' unless files.is_a?(Array) && files.length <= 20
      fingerprint = Digest::SHA256.hexdigest(JSON.generate([title,text,files.map { |f| f.slice('name','mime_type','sha256') }]))
      snapshot = ProjectbookKnowledge.new(wiki)
      existing = catalog(snapshot).find { |item| item['id'] == id }
      if existing
        raise Error.new('This request ID was already used for a different note.',409) unless existing['fingerprint'] == fingerprint
        return existing.merge('unchanged'=>true)
      end
      raise Error, 'Add text or an attachment.' if text.strip.empty? && files.empty?
      now = Time.now.utc
      title = "Raw note #{now.strftime('%Y-%m-%d %H:%M')}" if title.empty?
      folder = "raw-notes/#{now.strftime('%Y-%m-%d')}-#{id}"
      prepared = []; total = 0
      files.each_with_index do |file,i|
        mime = file.fetch('mime_type','').split(';').first
        ext = TYPES[mime]
        raise Error, 'Only photos and audio are supported; video is deferred.' unless ext
        id!(file['upload_id'])
        path = ::File.join(stage(wiki),file['upload_id'])
        raise Error, 'Attachment upload expired. Upload it again.' unless ::File.file?(path)
        bytes = ::File.binread(path,MAX_FILE+1)
        raise Error, 'Attachment must be 1 byte..20 MiB.' unless (1..MAX_FILE).cover?(bytes.bytesize)
        raise Error, 'Attachment checksum mismatch.' unless file['sha256'] == Digest::SHA256.hexdigest(bytes)
        total += bytes.bytesize
        raise Error, 'Note exceeds 50 MiB.' if total > MAX_TOTAL
        name = "#{mime.start_with?('image/') ? 'photo' : 'voice'}-#{format('%02d',i+1)}.#{ext}"
        prepared << [folder+'/media/'+name, bytes, mime, name]
      end
      body = ProjectbookTitles.markdown_heading(title)+"\n"+text+"\n"
      prepared.each do |_,_,mime,name|
        body += "\n#{mime.start_with?('image/') ? '!' : ''}[#{name}](media/#{name})\n"
      end
      meta = {'schema'=>1,'id'=>id,'created_at'=>now.iso8601(6),'source'=>input['source'] == 'mcp' ? 'mcp' : 'web','status'=>'unsorted','results'=>[], 'fingerprint'=>fingerprint,
        'attachments'=>prepared.map { |path,bytes,mime,name| {'path'=>path,'name'=>name,'mime_type'=>mime,'bytes'=>bytes.bytesize} }}
      writes = prepared.map { |path,bytes,*_| [path,bytes] } + [[folder+'/note.md',body],[folder+'/.note.json',JSON.pretty_generate(meta)+"\n"]]
      ProjectbookSave.destination!(wiki,folder+'/note.md')
      writes.each { |path,_| ProjectbookSave.disk_check!(wiki,path) }
      committer = Gollum::Committer.new(wiki, options.merge(message:'Create raw note'))
      writes.each { |path,bytes| wiki.write_file(path,bytes,committer:committer,normalize:false) }
      ProjectbookTree.append(wiki,committer,folder+'/note.md')
      commit = committer.commit
      files.each { |file| FileUtils.rm_f(::File.join(stage(wiki),file['upload_id'])) }
      catalog(ProjectbookKnowledge.new(wiki)).find { |item| item['id'] == id }.merge('commit'=>commit)
    end
    def self.status(wiki, id:, expected_version:, status:, results: [], options: {})
      raise Error.new('Editing is disabled.',403) unless wiki.allow_editing
      raise Error, 'Choose unsorted or processed.' unless %w[unsorted processed].include?(status)
      snapshot = ProjectbookKnowledge.new(wiki)
      note = catalog(snapshot).find { |item| item['id'] == id!(id) }
      raise Error.new('Note not found.',404) unless note
      raise Error.new('Note changed. Read it again.',412) unless note['version'] == expected_version
      raise Error, 'At most 20 result document paths.' unless results.is_a?(Array) && results.length <= 20
      results.each { |path| ProjectbookSave.path!(path); raise Error,'Result document not found.' unless snapshot.docs.any? { |e| e[:path] == path } }
      path = note['path'].sub('note.md','.note.json')
      entry = snapshot.entries.find { |e| e[:path] == path }; previous = snapshot.text(entry)
      meta = JSON.parse(previous).merge('status'=>status,'results'=>results)
      return note.merge('unchanged'=>true) if JSON.parse(previous) == meta
      ProjectbookSave.disk_check!(wiki,path,previous)
      committer = Gollum::Committer.new(wiki,options.merge(message:'Update raw note status'))
      committer.add(path,JSON.pretty_generate(meta)+"\n")
      committer.after_commit { |index,_| index.update_working_dir(path) }
      committer.commit
      fresh = Gollum::Wiki.new(wiki.path, ref: wiki.ref)
      catalog(ProjectbookKnowledge.new(fresh)).find { |item| item['id'] == id }
    end
  end
end
