require 'nokogiri'
module Gollum
  module ProjectbookCallouts
    TYPES = {'NOTE'=>'Note','TIP'=>'Tip','IMPORTANT'=>'Important','WARNING'=>'Warning','CAUTION'=>'Caution'}.freeze
    def self.render(html)
      doc = Nokogiri::HTML.fragment(html)
      doc.css('blockquote').each do |quote|
        first = quote.element_children.first
        next unless first&.name == 'p'
        text = first.children.first
        next unless text&.text?
        match = /\A\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\r?\n|\z)/.match(text.content)
        next unless match
        kind = match[1]
        text.content = text.content.delete_prefix(match[0])
        text.remove if text.content.empty?
        first.children.first.remove if first.children.first&.name == 'br'
        first.remove if first.children.empty?
        quote['class'] = [quote['class'], 'pb-callout', 'pb-callout-' + kind.downcase].compact.join(' ')
        quote['data-label'] = TYPES.fetch(kind)
        quote['data-callout'] = kind
      end
      doc.to_html
    end
  end
end
