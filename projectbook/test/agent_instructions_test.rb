require_relative 'mcp_test'
class AgentInstructionsTest < ProjectbookMCPTest
  def test_read_preview_save_conflict_and_context
    initial,error=tool('get_agent_instructions');refute error;assert_equal '',initial['version']
    input={content:"# Book preferences\nUse short dashes.\n",expected_version:''}
    before=head;preview,error=tool('set_agent_instructions',input);refute error;assert preview['dry_run'];assert_equal before,head
    saved,error=tool('set_agent_instructions',input.merge(dry_run:false));refute error;assert saved['commit']
    current,error=tool('get_agent_instructions');refute error;assert_equal input[:content],current['content']
    context,error=tool('get_book_context');refute error;assert_equal current,context['agent_instructions']
    _,error=tool('set_agent_instructions',input.merge(content:'Overwrite',dry_run:false));assert error
    result,error=tool('set_agent_instructions',input.merge(expected_version:current['version'],dry_run:false));refute error;assert result['unchanged']
  end
  def test_write_permission_and_hidden_tree
    ENV['PROJECTBOOK_MCP_DOCUMENT_WRITE']='false'
    response=rpc('tools/list');names=JSON.parse(response.body)['result']['tools'].map{|t|t['name']};refute_includes names,'set_agent_instructions';assert_includes names,'get_agent_instructions'
  end
end
