# Focused regression checks; no git init/commit and no document writes.
require 'minitest/autorun'
require 'gollum-lib'
require_relative '../../lib/gollum/navigation_index'
require_relative '../extensions/document_tree'

class NavigationIndexTest < Minitest::Test
  Entry = Struct.new(:path) do
    def name; File.basename(path); end
  end
  class Wiki
    attr_accessor :revision, :paths
    attr_reader :calls, :path, :ref, :page_file_dir
    def initialize(prefix = nil)
      @path, @ref, @page_file_dir = "/fixture-#{object_id}", 'main', prefix
      @revision, @paths, @calls = 'first', ['Home.md', 'folder/a.md', 'folder/photo.jpg', 'big.pdf'], 0
    end
    def commit_for(_); Struct.new(:id).new(revision); end
    def tree_map_for(_); @calls += 1; paths.map { |p| Entry.new(p) }; end
    def tree_list; raise 'Must never load page/file blobs for navigation'; end
  end

  def test_reuses_index_until_local_ref_changes_including_rewind
    wiki = Wiki.new
    first = Gollum::NavigationIndex.for(wiki)
    assert_same first, Gollum::NavigationIndex.for(wiki)
    assert_equal 1, wiki.calls
    assert_equal wiki.paths, first.entries.map(&:url_path)
    wiki.revision = 'second'; wiki.paths = ['renamed.md']
    second = Gollum::NavigationIndex.for(wiki)
    refute_same first, second
    assert_equal ['renamed.md'], second.entries.map(&:url_path)
    wiki.revision = 'first'; wiki.paths = ['Home.md']
    assert_equal ['Home.md'], Gollum::NavigationIndex.for(wiki).entries.map(&:url_path)
    assert_equal 3, wiki.calls
  end

  def test_snapshots_are_not_mutable_and_html_is_cached_by_base_path
    wiki = Wiki.new
    snapshot = Gollum::NavigationIndex.for(wiki)
    assert_raises(FrozenError) { snapshot.entries.clear }
    assert_raises(FrozenError) { snapshot.entries.first.path.replace('bad') }
    assert_equal 'first', snapshot.tree_html('') { 'first' }
    assert_equal 'first', snapshot.tree_html('') { raise 're-rendered' }
    assert_equal 'nested', snapshot.tree_html('/wiki') { 'nested' }
  end

  def test_page_directory_urls_and_protected_files
    wiki = Wiki.new('docs')
    wiki.paths = ['docs/Name with space.md', 'docs/custom.js', 'docs/image.png']
    entries = Gollum::NavigationIndex.for(wiki).entries
    assert_equal ['Name with space.md', 'image.png'], entries.map(&:url_path)
    assert_equal 'Name%20with%20space.md', entries.first.escaped_url_path
  end

  def test_escaped_collapsed_folders_are_separate_from_links
    view = Object.new.extend(ProjectBookDocumentTree)
    def view.base_url; '/wiki'; end
    view.instance_variable_set(:@projectbook_folder_number, 0)
    html = view.send(:projectbook_render_nodes, {'<a & b>' => {children: {'two words.md' => {path: '<a & b>/two words.md'}}}})
    assert_includes html, 'aria-expanded="false"'
    assert_includes html, ' hidden>'
    assert_includes html, 'data-folder-link="&lt;a &amp; b&gt;"'
    assert_includes html, '/wiki/gollum/overview/%3Ca%20%26%20b%3E/'
    assert_includes html, 'two%20words.md'
    refute_includes html, '<a & b>'
  end
  def test_media_links_use_preview_while_markdown_links_open_pages
    view = Object.new.extend(ProjectBookDocumentTree)
    def view.base_url; ''; end
    html = view.send(:projectbook_render_nodes, {'logo.png' => {path: 'logo.png'}, 'Home.md' => {path: 'Home.md'}})
    assert_includes html, 'href="/gollum/file/logo.png"'
    assert_includes html, 'href="/Home.md"'
  end

end
