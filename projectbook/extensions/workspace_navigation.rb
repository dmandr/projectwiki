module ProjectBookWorkspaceNavigation
  def projectbook_can_create
    @allow_editing
  end

  def projectbook_object_path
    return @page.url_path if @page
    return @file.url_path if @file
    @path.to_s.sub(%r{\A/+}, '').sub(%r{/+\z}, '')
  end

  def projectbook_parent
    if @page || @file
      parent = ::File.dirname(projectbook_object_path)
      parent == '.' ? '' : parent
    else
      projectbook_object_path
    end
  end

  def projectbook_folders
    wiki = Gollum::Wiki.new(Precious::App.gollum_path, Precious::App.wiki_options)
    folders = ['']
    Gollum::NavigationIndex.for(wiki).entries.each do |entry|
      parts = entry.url_path.split('/')[0...-1]
      parts.length.times { |i| folders << parts[0..i].join('/') }
    end
    folders.uniq.sort.map { |folder| {value: folder, label: folder.empty? ? '/ (book root)' : '/' + folder, selected: folder == projectbook_parent} }
  end

  def projectbook_breadcrumbs
    parts = projectbook_object_path.split('/').reject(&:empty?)
    [{label: 'Files', url: overview_path}] + parts.each_with_index.map do |part, i|
      path = parts[0..i].join('/')
      url = if i == parts.length - 1 && (@page || @file)
        @file ? page_route('gollum/file/' + Gollum::NavigationIndex.encode_path(path)) : page_route(Gollum::NavigationIndex.encode_path(path))
      else
        overview_path + '/' + Gollum::NavigationIndex.encode_path(path) + '/'
      end
      {label: part, url: url}
    end
  end

  def projectbook_history_url
    return latest_changes_path unless @page
    home = @page.url_path.sub(/\.[^\/.]+\z/, '') == @page.wiki.index_page.sub(/\.[^\/.]+\z/, '')
    home && !projectbook_history_screen ? latest_changes_path : history_path + '/' + @page.escaped_url_path
  end

  def projectbook_history_screen
    %w[History LatestChanges].include?(self.class.name.split('::').last)
  end

  def projectbook_history_options
    wiki = @page ? @page.wiki : Gollum::Wiki.new(Precious::App.gollum_path, Precious::App.wiki_options)
    [{label: 'Entire book', url: latest_changes_path, selected: !@page}] +
      Gollum::NavigationIndex.for(wiki).entries.select { |entry| Gollum::Page.valid_page_name?(entry.filename) }.sort_by(&:url_path).map do |entry|
        {label: "#{entry.title} — #{entry.url_path}", url: history_path + '/' + entry.escaped_url_path, selected: @page && entry.url_path == @page.url_path}
      end
  end

  def projectbook_edit_url
    @page && @allow_editing && !projectbook_editing ? edit_path + '/' + @page.escaped_url_path : nil
  end

  def projectbook_editing
    respond_to?(:is_edit_page) && is_edit_page
  end

  def projectbook_rename
    projectbook_editing && @allow_editing
  end

  def projectbook_attachment; !!@file; end
  def projectbook_download
    return nil unless @page || @file
    page_route(Gollum::NavigationIndex.encode_path(projectbook_object_path)) + (@page ? '?raw' : '')
  end
end
