require 'cgi'
require 'gollum/navigation_index'
require 'gollum/projectbook_tree'

module ProjectBookDocumentTree
  def projectbook_tree_html
    wiki = Gollum::Wiki.new(Precious::App.gollum_path, Precious::App.wiki_options)
    snapshot = (@projectbook_navigation_snapshot ||= Gollum::NavigationIndex.for(wiki))
    snapshot.tree_html(base_url.to_s) do |entries|
      root = {}
      entries.each do |entry|
        parts = entry.url_path.split('/')
        leaf = parts.pop
        folder = parts.inject(root) { |node, part| (node[part] ||= { children: {} })[:children] }
        folder[leaf] = { path: entry.url_path, title: entry.title } unless leaf == '.gitkeep'
      end
      @projectbook_tree_wiki = wiki
      @projectbook_tree_revision = snapshot.revision
      @projectbook_order_folders = wiki.tree_map_for(snapshot.revision).filter_map { |entry| Gollum::ProjectbookTree.parent(entry.path) if entry.name == '.order' }
      @projectbook_folder_number = 0
      projectbook_render_nodes(root)
    end
  end

  def projectbook_tree_revision
    wiki = Gollum::Wiki.new(Precious::App.gollum_path, Precious::App.wiki_options)
    (@projectbook_navigation_snapshot ||= Gollum::NavigationIndex.for(wiki)).revision
  end

  private

  def projectbook_render_nodes(nodes, parent = '')
    order = @projectbook_tree_wiki && @projectbook_order_folders.include?(parent) ? Gollum::ProjectbookTree.read_order(@projectbook_tree_wiki, parent, @projectbook_tree_revision) : []
    visible = nodes.reject { |name, node| !parent.empty? && name == '.index.md' && !node[:children] }
    visible.sort_by { |name, node| [node[:children] ? 0 : 1, name.downcase] }.sort_by { |name, _| order.index(name) || order.length }.map do |name, node|
      path = [parent, name].reject(&:empty?).join('/')
      escaped_path = CGI.escapeHTML(path)
      label = CGI.escapeHTML(node[:title] || name)
      encoded = Gollum::NavigationIndex.encode_path(path)
      if node[:children]
        landing = node[:children]['.index.md']
        landing = nil if landing && landing[:children]
        label = CGI.escapeHTML(landing[:title] || name) if landing
        @projectbook_folder_number += 1
        id = "projectbook-folder-#{@projectbook_folder_number}"
        url = CGI.escapeHTML(base_url.to_s + (landing ? '/' + encoded + '/.index.md' : '/gollum/overview/' + encoded + '/'))
        %(<li data-folder="#{escaped_path}"><div class="projectbook-tree-row"><button type="button" class="projectbook-toggle" aria-expanded="false" aria-controls="#{id}" aria-label="Expand #{label}" title="Expand #{label}"><svg aria-hidden="true" viewBox="0 0 16 16"><path d="m6 3 5 5-5 5"/></svg></button><a data-folder-link="#{escaped_path}" href="#{url}" title="#{escaped_path}">#{label}</a></div><ul id="#{id}" hidden>#{projectbook_render_nodes(node[:children], path)}</ul></li>)
      else
        prefix = Gollum::Page.valid_page_name?(name) ? '/' : '/gollum/file/'
        url = CGI.escapeHTML(base_url.to_s + prefix + encoded)
        %(<li class="projectbook-file"><a data-document="#{escaped_path}" href="#{url}" title="#{escaped_path}">#{label}</a></li>)
      end
    end.join
  end
end
