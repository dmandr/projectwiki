# Run against an isolated clean clone first; no push and no implicit startup migration.
require 'gollum/app'
require 'gollum/projectbook_inline_todo_migration'
root=ARGV.fetch(0)
wiki=Gollum::Wiki.new(root,ref:ENV.fetch('GOLLUM_REF','main'))
result=Gollum::ProjectbookInlineTodoMigration.run(wiki,dry_run:!ARGV.include?('--apply'))
puts JSON.pretty_generate(result.merge(changes:result[:changes].map { |c| c.reject { |k,_| [:content,:previous_content].include?(k) } }))
