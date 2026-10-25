require 'securerandom'
require 'json'
require 'open3'
require 'timeout'

module Gollum
  module ProjectbookLocalAssets
    Error = ProjectbookCreation::Error
    UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
    def self.asset?(path)
      parts=path.to_s.split('/',-1)
      parts.length==3 && parts[0]=='.asset' && parts[1].match?(/\A#{UUID}\z/) &&
        !parts[2].empty? && !parts[2].start_with?('.', '_') && !parts[2].match?(/[\\%\x00-\x1f\x7f]/)
    end
    def self.readable?(snapshot,path)
      asset?(path) && snapshot.entries.any? { |e| e[:path]==path }
    end
    def self.rewrite(documents,paths,mapping, destinations: {}, asset_fallback: false)
      runner=ENV.fetch('PROJECTBOOK_LINK_REWRITER','/experiment/editor/dist/book-links.cjs')
      output,_,status=Timeout.timeout(60) { Open3.capture3('node',runner,stdin_data:JSON.generate(documents:documents,paths:paths,mapping:mapping,destinations:destinations,assetFallback:asset_fallback)) }
      raise Error,'Could not parse attachment links. Nothing was saved.' unless status.success?
      JSON.parse(output).to_h { |d| [d.fetch('path'),d.fetch('content')] }
    rescue Timeout::Error, Errno::ENOENT, JSON::ParserError
      raise Error,'Attachment link processor unavailable. Nothing was saved.'
    end
    def self.copy(wiki,source:,target:,revision:,dry_run:true,options:{})
      ProjectbookSave.path!(source);ProjectbookSave.path!(target)
      snapshot=ProjectbookKnowledge.new(wiki);ProjectbookMove.clean!(snapshot,wiki)
      raise Error.new('The book changed. Preview again.',412) unless revision==snapshot.revision
      ProjectbookSave.destination!(wiki,target)
      entry=snapshot.entries.find { |e| e[:path]==source && snapshot.markdown?(e) }
      raise Error,'Source page not found.' unless entry
      mapping={source=>target};writes={}
      writes[target]=rewrite([{path:source,content:snapshot.text(entry)}],snapshot.entries.map { |e|e[:path] },mapping,destinations:{source=>target}).fetch(source)
      writes.each { |p,_| ProjectbookSave.disk_check!(wiki,p) }
      return {revision:revision,path:target,files:writes.keys} if dry_run
      raise Error.new('Editing is disabled.',403) unless wiki.allow_editing
      committer=Gollum::Committer.new(wiki,options.merge(message:"Copy #{source} to #{target} with shared attachment links"))
      writes.each { |p,bytes|committer.add(p,bytes);committer.after_commit { |index,_|index.update_working_dir(p) } }
      ProjectbookTree.append(wiki,committer,target)
      {path:target,commit:committer.commit}
    end
    # Text pasted from other pages reuses immutable assets; it does not copy bytes.
    def self.paste(wiki,content,path)
      ProjectbookSave.path!(path)
      raise Error,'Clipboard text exceeds 2 MiB.' unless content.is_a?(String) && content.bytesize<=2*1024*1024
      snapshot=ProjectbookKnowledge.new(wiki)
      text=rewrite([{path:path,content:content}],snapshot.entries.map { |e|e[:path] },{},asset_fallback:true).fetch(path)
      {content:text,attachments:[]}
    end
    def self.prepare_uploads(wiki,source,target,content,prepared,link_source:source)
      return [content,prepared] if prepared.empty?
      snapshot=ProjectbookKnowledge.new(wiki);mapping={}
      files=prepared.map do |old,temp|
        # The draft's UUID makes preview/apply deterministic. Never overwrite.
        path=old.sub(/\Auploads\//,'.asset/')
        raise Error,'Invalid asset path.' unless asset?(path)
        raise Error.new('Attachment already exists; attach again.',409) if wiki.file(path)
        ProjectbookSave.disk_check!(wiki,path)
        mapping[old]=path
        [path,temp]
      end
      text=rewrite([{path:link_source,content:content}],snapshot.entries.map { |e|e[:path] }+mapping.keys,mapping,asset_fallback:true).fetch(link_source)
      [text,files]
    end
  end
end
