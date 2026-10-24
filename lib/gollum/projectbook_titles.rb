require 'kramdown'
require 'kramdown-parser-gfm'
require 'nokogiri'

module Gollum
  module ProjectbookTitles
    def self.from_path(path)
      ::File.basename(path.to_s).sub(/\.(md|markdown|mdown|mkdn)\z/i, '').tr('_-', ' ').split.map { |word| word.sub(/\A./) { |c| c.upcase } }.join(' ')
    end

    def self.input_title(value)
      raise ProjectbookCreation::Error, 'Enter a title on one line (up to 180 characters).' unless value.is_a?(String) && !value.strip.empty? && value.length <= 180 && !value.match?(/[\x00-\x1f\x7f]/)
      value = value.strip
      value.match?(/\A[\p{Ll}\p{N}]+(?:[-_][\p{Ll}\p{N}]+)+\z/) ? from_path(value) : value
    end

    def self.frontmatter(source)
      match = source.match(/\A(?:---\r?\n.*?\r?\n---|\+\+\+\r?\n.*?\r?\n\+\+\+)(?:\r?\n|\z)/m)
      match ? [match[0], source[match[0].length..]] : ['', source]
    end

    def self.heading(source)
      body = frontmatter(source)[1]
      document = Kramdown::Document.new(body, input: 'GFM')
      node = document.root.children.find { |item| item.type != :blank }
      return nil unless node && node.type == :header && node.options[:level] == 1
      document.root.children.replace([node])
      html = document.to_html
      text = Nokogiri::HTML.fragment(html).text.strip
      text.empty? ? nil : text
    end

    def self.title(source, path)
      heading(source) || from_path(path)
    end

    def self.markdown_heading(title)
      '# ' + title.gsub('&', '&amp;').gsub(/[\\`*_{}\[\]()<>#+.!|~]/) { |c| "\\#{c}" } + "\n\n"
    end

    def self.ensure_title(source, path)
      return source if heading(source)
      metadata, body = frontmatter(source)
      metadata + (metadata.empty? ? '' : "\n") + markdown_heading(from_path(path)) + body.sub(/\A\s*\n/, '')
    end
  end
end
