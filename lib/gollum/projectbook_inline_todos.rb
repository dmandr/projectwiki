require 'json'
require 'digest/sha1'
require 'open3'
require 'time'
require 'timeout'
require 'uri'

module Gollum
  # Source documents are authoritative. Locations are valid only for a blob SHA;
  # no task identity is persisted in Markdown or in an independent task file.
  module ProjectbookInlineTodos
    Error = ProjectbookCreation::Error
    @cache = {}
    @lock = Mutex.new
    def self.scan(documents)
      return [] if documents.empty?
      raise Error, 'TODO scan exceeds 64 MiB.' if documents.sum { |d| d[:content].bytesize } > 64 * 1024 * 1024
      runner = ENV.fetch('PROJECTBOOK_TODO_PARSER', '/experiment/editor/dist/inline-todo.cjs')
      output, _, status = Timeout.timeout(60) { Open3.capture3('node', runner, stdin_data: JSON.generate(documents: documents)) }
      raise Error, 'Could not parse TODOs. No documents were changed.' unless status.success?
      JSON.parse(output)
    rescue Timeout::Error, JSON::ParserError
      raise Error, 'TODO parsing failed. No documents were changed.'
    end
    def self.catalog(snapshot)
      docs = snapshot.docs.reject { |e| e[:local] || ProjectbookTasks.identity(e[:path]) }
      key = docs.map { |e| [e[:path], e[:sha]] }
      @lock.synchronize do
        if @cache.key?(key)
          return @cache[key].merge(revision: snapshot.revision)
        end
        errors=[]
        readable=docs.select do |e|
          if e[:bytes] > ProjectbookKnowledge::MAX_TEXT
            errors << {path:e[:path],error:'Document exceeds the 2 MiB TODO scan limit.'};false
          else true end
        end
        documents=readable.map { |e| {path:e[:path],content:snapshot.text(e)} }
        versions=readable.to_h { |e| [e[:path],e[:sha]] }
        result=scan(documents)
        tasks=result.flat_map do |doc|
          doc['tasks'].map.with_index { |task,index| task.merge('path'=>doc['path'],'version'=>versions.fetch(doc['path']),'ordinal'=>index) }
        end
        value={tasks:tasks,tags:tasks.flat_map { |t| t['tags'] }.uniq.sort,errors:errors}
        @cache.shift while @cache.length >= 4
        @cache[key]=value
        value.merge(revision:snapshot.revision)
      end
    end
    def self.tags!(tags)
      raise Error, 'Use up to 30 text tags.' unless tags.is_a?(Array) && tags.length<=30 && tags.all? { |t| t.is_a?(String) && t.strip.length.between?(1,80) && !t.match?(/[\x00-\x1f\x7f,]/) }
      tags.map(&:strip).uniq.sort
    end
    def self.normalize(data)
      title=data['title']
      raise Error, 'TODO text must be 1..2000 characters on one line.' unless title.is_a?(String) && title.strip.length.between?(1,2000) && !title.match?(/[\x00-\x1f\x7f]/)
      done=data.fetch('done','')
      raise Error, 'Use an ISO date/time for done, or an empty string.' unless done.is_a?(String) && (done.empty? || /\A\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d(?:\.\d{1,3})?)?(?:Z|[+-]\d\d:\d\d)?\z/.match?(done))
      DateTime.iso8601(done) unless done.empty?
      {'title'=>title.strip,'done'=>done,'tags'=>tags!(data.fetch('tags',[]))}
    rescue Date::Error
      raise Error, 'Invalid completion date/time.'
    end
    def self.encode(value)
      URI::DEFAULT_PARSER.escape(value, /[^A-Za-z0-9\-._~]/)
    end
    def self.markdown(data)
      data=normalize(data)
      title=data['title'].gsub(/[\\\[\]*_`<>]/) { |c| '\\'+c }
      meta=[]
      meta << 'done='+data['done'] unless data['done'].empty?
      meta << 'tags='+data['tags'].map { |t| encode(t) }.join(',') unless data['tags'].empty?
      "[TODO: #{title}](#{meta.join(',')})"
    end
    def self.prepare(wiki,changes)
      raise Error.new('Editing is disabled.',403) unless wiki.allow_editing
      raise Error, 'Use 1..100 TODO changes.' unless changes.is_a?(Array) && changes.length.between?(1,100)
      snapshot=ProjectbookKnowledge.new(wiki)
      catalog=catalog(snapshot)
      changes.group_by { |c| c.is_a?(Hash) ? c['path'] : nil }.map do |path,items|
        ProjectbookSave.path!(path)
        entry=snapshot.docs.find { |e| e[:path]==path && !e[:local] }
        raise Error.new('TODO document not found.',404) unless entry
        raise Error.new('The source document changed. Refresh the TODO list before editing.',412) unless items.all? { |c| c['expected_version']==entry[:sha] }
        old=snapshot.text(entry); content=old.b.dup;seen=[]
        items.sort_by { |c| -(c['start'].is_a?(Integer) ? c['start'] : -1) }.each do |change|
          start=change['start']
          raise Error, 'Duplicate or invalid TODO location.' unless start.is_a?(Integer) && start>=0 && !seen.include?(start)
          seen << start
          task=catalog[:tasks].find { |t| t['path']==path && t['start']==start }
          raise Error.new('TODO no longer exists at this location. Refresh the list.',412) unless task
          content[start...task['end']]=markdown(change).b
        end
        page=wiki.page(path)
        raise Error.new('Source document changed.',412) unless page && page.sha==entry[:sha]
        ProjectbookSave.disk_check!(wiki,path,old)
        {path:path,page:page,content:content.force_encoding(Encoding::UTF_8),previous_content:old}
      end.reject { |item| item[:content]==item[:previous_content] }
    end
    def self.save(wiki,changes,options,dry_run:false)
      prepared=prepare(wiki,changes)
      result={dry_run:dry_run,unchanged:prepared.empty?,changes:prepared.map { |p| p.slice(:path,:content,:previous_content) }}
      return result if dry_run || prepared.empty?
      committer=Gollum::Committer.new(wiki,options)
      prepared.each do |item|
        committer.add(item[:page].path,item[:content])
        committer.after_commit { |index,_| index.update_working_dir(item[:page].path) }
      end
      result.merge(commit:committer.commit,versions:prepared.to_h { |p| [p[:path],Digest::SHA1.hexdigest("blob #{p[:content].bytesize}\0"+p[:content])] })
    end
  end
end
