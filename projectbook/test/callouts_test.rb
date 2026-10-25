require 'minitest/autorun'
require 'github/markup'
require 'gollum/projectbook_callouts'
class CalloutsTest < Minitest::Test
  def render(md)
    Nokogiri::HTML.fragment(Gollum::ProjectbookCallouts.render(GitHub::Markup.render('test.md',md)))
  end
  def test_lists_and_formatting_survive
    Gollum::ProjectbookCallouts::TYPES.each_key do |kind|
      doc=render("> [!#{kind}]\n> **Before starting:**\n>\n> - Check oil.\n> - Open seacock.\n>\n> [Manual](engine.md)\n")
      assert_equal 1,doc.css(".pb-callout-#{kind.downcase}").length
      assert_equal 2,doc.css('.pb-callout li').length
      assert_equal 'Before starting:',doc.at_css('.pb-callout strong').text
      assert_equal 'engine.md',doc.at_css('.pb-callout a')['href']
      refute_includes doc.text,"[!#{kind}]"
    end
  end
  def test_code_examples_and_unknown_quotes_are_unchanged
    doc=render("```md\n> [!WARNING]\n> example\n```\n\n> [!OTHER]\n> plain quote")
    assert_empty doc.css('.pb-callout')
    assert_includes doc.at_css('code').text,'[!WARNING]'
  end
  def test_marker_only_paragraph_and_footnotes
    doc=render("> [!NOTE]\n>\n> One\n>\n> Two\n\nText[^one].\n\n[^one]: A **bold** footnote.\n")
    assert_equal ['One','Two'],doc.css('.pb-callout p').map(&:text)
    assert_equal 'bold',doc.at_css('.footnotes strong').text
    assert doc.at_css('[role="doc-noteref"]')
  end
end
