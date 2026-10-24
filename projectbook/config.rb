# Configuration belongs to the experiment, not to the shared content repository.
Precious::App.set(:wiki_options, Precious::App.wiki_options.merge(
  ref: ENV.fetch('GOLLUM_REF', 'main'),
  index_page: 'Home',
  h1_title: true,
  sidebar: :left,
  allow_uploads: ENV['GOLLUM_READ_ONLY'] != 'true',
  allow_editing: ENV['GOLLUM_READ_ONLY'] != 'true'
))
Precious::App.set(:default_markup, :markdown)

if ENV.fetch('GOLLUM_TREE', 'true') == 'true'
  require_relative 'extensions/document_tree'
  Precious::Views::Layout.include(ProjectBookDocumentTree)
end

module ProjectBookEditorView
  def projectbook_mdx_editor
    ENV.fetch('GOLLUM_EDITOR', 'mdx') == 'mdx' && (!respond_to?(:format) || format == 'markdown')
  end

  def projectbook_editor_path
    return @page.url_path if @page
    [@path.to_s.sub(%r{^/+}, '').sub(%r{/+$}, ''), @name.to_s + (@ext.to_s.empty? ? '.md' : @ext.to_s)].reject(&:empty?).join('/')
  end

  def projectbook_tree_enabled
    ENV.fetch('GOLLUM_TREE', 'true') == 'true'
  end
end
Precious::Views::Layout.include(ProjectBookEditorView)
if ENV.fetch('GOLLUM_EDITOR', 'mdx') == 'mdx' || ENV.fetch('GOLLUM_TREE', 'true') == 'true'
  require 'rack/static'
  Precious::App.use Rack::Static, urls: ['/projectbook-editor'], root: '/experiment/editor/dist'
end
if ENV.fetch('GOLLUM_TREE', 'true') == 'true' || ENV.fetch('GOLLUM_EDITOR', 'mdx') == 'mdx'
  Precious::App.wiki_options[:template_dir] = File.join(__dir__, 'templates')
end

require_relative 'extensions/workspace_navigation'
Precious::Views::Layout.include(ProjectBookWorkspaceNavigation)
