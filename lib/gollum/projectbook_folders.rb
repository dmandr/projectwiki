require 'gollum/projectbook_creation'
require 'json'
require 'cgi'
require 'nokogiri'
module Gollum
  module ProjectbookFolders
    Error = ProjectbookCreation::Error
    PAGE = '.index.md'
    BLOCK = '[Pages](#projectbook-pages)'
    def self.page?(path)
      parts = path.to_s.split('/')
      parts.length > 1 && parts.last == PAGE && parts[0...-1].all? { |part| !part.empty? && !part.start_with?('.', '_') }
    end
    def self.folder!(path)
      ProjectbookSave.path!(path)
      path.split('/').each { |part| ProjectbookCreation.segment!(part) }
      path
    end
    def self.create(wiki, folder:, title:, options: {}, existing: false)
      raise Error.new('Editing is disabled.',403) unless wiki.allow_editing
      folder!(folder)
      snapshot = ProjectbookKnowledge.new(wiki)
      present = snapshot.entries.any? { |entry| entry[:path].start_with?(folder+'/') }
      raise Error.new(existing ? 'Folder no longer exists.' : 'Folder already exists.',409) if present != existing
      title = ProjectbookTitles.input_title(title)
      ProjectbookSave.save(wiki,{'path'=>folder+'/'+PAGE,'create'=>true,'content'=>ProjectbookTitles.markdown_heading(title)+BLOCK+"\n"},[],options.merge(message:"Create folder page #{folder}"))
    end
    def self.items(wiki, folder, revision: nil, base: '')
      snapshot = ProjectbookKnowledge.new(wiki,revision: revision)
      ProjectbookTree.ordered(wiki,snapshot,folder).map do |name|
        path = folder+'/'+name
        entry = snapshot.entries.find { |e| e[:path] == path }
        if entry
          title = snapshot.markdown?(entry) ? ProjectbookTitles.title(snapshot.text(entry),path) : name
          url = base+(snapshot.markdown?(entry) ? '/' : '/gollum/file/')+NavigationIndex.encode_path(path)
        else
          landing = snapshot.entries.find { |e| e[:path] == path+'/'+PAGE }
          title = landing ? ProjectbookTitles.title(snapshot.text(landing),landing[:path]) : ProjectbookTitles.from_path(path)
          url = base+'/gollum/overview/'+NavigationIndex.encode_path(path)+'/'
        end
        {title: title, path: path, url: url, folder: entry.nil?}
      end
    end
    def self.render(html, page, base: '', revision: nil)
      return html unless page?(page.url_path) && html.include?('projectbook-pages')
      document = Nokogiri::HTML.fragment(html)
      document.css('a[href="#projectbook-pages"]').each do |link|
        parent = link.parent
        next unless parent.name == 'p' && parent.text.strip == link.text.strip
        values = items(page.wiki,::File.dirname(page.url_path),revision:revision,base:base)
        if values.empty?; parent.remove; next; end
        block = Nokogiri::XML::Node.new('section',document);block['class']='pb-subpages'
        heading = Nokogiri::XML::Node.new('h2',document);heading.content='Pages';block.add_child(heading)
        list = Nokogiri::XML::Node.new('ul',document);block.add_child(list)
        values.each do |item|
          li=Nokogiri::XML::Node.new('li',document);a=Nokogiri::XML::Node.new('a',document)
          a['href']=item[:url];a.content=item[:title];li.add_child(a);list.add_child(li)
        end
        parent.replace(block)
      end
      document.to_html
    end
    def self.delete_preview(wiki, folder)
      folder!(folder)
      snapshot=ProjectbookKnowledge.new(wiki)
      ProjectbookMove.clean!(snapshot,wiki)
      entries=snapshot.entries.select { |e| e[:path].start_with?(folder+'/') }
      raise Error.new('Folder no longer exists.',404) if entries.empty?
      raw=snapshot.git('ls-tree','-rz',snapshot.revision).split("\0")
      raise Error, 'Folders containing symlinks or submodules cannot be deleted here.' if raw.any? { |r| h,p=r.split("\t",2);p && p.start_with?(folder+'/') && !%w[100644 100755].include?(h.split.first) }
      {folder:folder,revision:snapshot.revision,files:entries.length,documents:entries.count { |e| snapshot.markdown?(e) }}
    end
    def self.delete(wiki, folder:, revision:, confirmed_folder:, options: {})
      raise Error.new('Editing is disabled.',403) unless wiki.allow_editing
      raise Error, 'Explicit confirmation of the entire folder is required.' unless confirmed_folder == folder
      preview=delete_preview(wiki,folder)
      raise Error.new('The book changed. Review the folder deletion again.',412) unless revision == preview[:revision]
      snapshot=ProjectbookKnowledge.new(wiki)
      entries=snapshot.entries.select { |e| e[:path].start_with?(folder+'/') }
      entries.each { |e| ProjectbookSave.disk_check!(wiki,e[:path],wiki.file(e[:path]).raw_data) }
      committer=Gollum::Committer.new(wiki,options.merge(message:"Delete folder #{folder}"))
      entries.each { |e| wiki.delete_file(e[:path],committer:committer) }
      ProjectbookTree.remove(wiki,committer,folder)
      preview.merge(commit:committer.commit)
    end
  end
end
