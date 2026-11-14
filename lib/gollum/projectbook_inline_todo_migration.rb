require 'gollum/projectbook_inline_todos'
module Gollum
  module ProjectbookInlineTodoMigration
    Error=ProjectbookCreation::Error
    def self.done_at(snapshot,entry,task)
      return '' unless task['status']=='done'
      lines=snapshot.text(entry).lines
      line=lines.index { |l| l.include?('"status": "done"') }
      if line
        blame=snapshot.git('blame','--line-porcelain','-L',"#{line+1},#{line+1}",snapshot.revision,'--',entry[:path])
        epoch=blame[/^committer-time (\d+)$/,1]
        return Time.at(epoch.to_i).utc.iso8601 if epoch
      end
      raise Error, "Cannot recover completion commit time for #{entry[:path]}."
    end
    def self.plan(wiki)
      snapshot=ProjectbookKnowledge.new(wiki)
      entries=snapshot.entries.select { |e| ProjectbookTasks.identity(e[:path]) }
      return {revision:snapshot.revision,changes:[],remove:[],definitions:0} if entries.empty?
      catalog=ProjectbookTasks.catalog(snapshot)
      raise Error, 'Fix invalid legacy TODO metadata before migration.' unless catalog[:errors].empty?
      lists=catalog[:lists].to_h { |l| [l['id'],l] }
      tasks=catalog[:tasks].to_h do |t|
        entry=entries.find { |e| e[:path]==t['path'] }
        list=lists[t['list_id']]
        raise Error, "Missing list for #{t['path']}" unless list
        [t['id'],t.merge('done'=>done_at(snapshot,entry,t),'tags'=>[list['title']])]
      end
      docs=snapshot.docs.reject { |e| ProjectbookTasks.identity(e[:path]) || e[:local] }.map { |e| {path:e[:path],content:snapshot.text(e)} }
      parsed=ProjectbookInlineTodos.scan(docs)
      contents=docs.to_h { |d| [d[:path],d[:content]] }; referenced=[];count=0
      changes=parsed.filter_map do |doc|
        old=contents.fetch(doc['path']);updated=old.b.dup
        doc['legacy'].reverse_each do |ref|
          if ref['kind']=='task'
            task=tasks[ref['id']];raise Error,"Missing task #{ref['id']} in #{doc['path']}" unless task
            replacement=ProjectbookInlineTodos.markdown(task);referenced<<task['id'];count+=1
          else
            list=lists[ref['id']];raise Error,"Missing list #{ref['id']}" unless list
            replacement="\n\n:::todos\ntags: #{list['title']}\nmatch: any\nstatus: #{ref['status']}\n:::\n\n"
          end
          updated[ref['start']...ref['end']]=replacement.b
        end
        updated.force_encoding(Encoding::UTF_8)
        # Legacy checklist wrappers already carry a checkbox; the definition now owns it.
        updated.gsub!(/^([ \t]*)(?:[-+*]|\d+[.)])\s+\[[ xX]\]\s+(?=\[TODO:)/,'\\1')
        next if updated==old
        {path:doc['path'],content:updated,previous_content:old}
      end
      retained=[]
      tasks.each_value do |t|
        unless referenced.include?(t['id'])
          retained << ProjectbookInlineTodos.markdown(t);count+=1
        end
        if !t['notes'].to_s.empty? || !t['due'].to_s.empty?
          retained << "## Legacy details: #{t['title']}\n\n" + (t['due'].to_s.empty? ? '' : "Former due date: #{t['due']}\n\n") + t['notes'].to_s
        end
      end
      lists.each_value { |l| retained << "## Former list notes: #{l['title']}\n\n#{l['notes']}" unless l['notes'].to_s.empty? }
      unless retained.empty?
        path='todo-migration-recovered.md'
        raise Error,'Recovery document already exists. Choose another recovery path before migration.' if snapshot.entries.any? { |e| e[:path]==path }
        changes << {path:path,content:"# Recovered TODOs and legacy details\n\nTasks without document references and additional legacy notes are preserved below. Completion timestamps are recovered from the Git commit that last set the legacy done status.\n\n"+retained.join("\n\n")+"\n",previous_content:nil}
      end
      {revision:snapshot.revision,changes:changes,remove:entries.map { |e| e[:path] },definitions:count}
    end
    def self.run(wiki,dry_run:true)
      plan=plan(wiki)
      return plan if dry_run || plan[:remove].empty?
      snapshot=ProjectbookKnowledge.new(wiki)
      ProjectbookMove.clean!(snapshot,wiki)
      raise Error,'The book changed. Rebuild the migration preview.' unless snapshot.revision==plan[:revision]
      commit=Gollum::Committer.new(wiki,name:'ProjectBook',email:'projectbook@local',message:'Migrate TODO definitions into source documents')
      plan[:changes].each do |item|
        if item[:previous_content]
          page=wiki.page(item[:path]);raise Error,"Cannot read #{item[:path]}" unless page
          ProjectbookSave.disk_check!(wiki,item[:path],item[:previous_content])
          commit.add(page.path,item[:content]);commit.after_commit { |index,_| index.update_working_dir(page.path) }
        else
          ProjectbookSave.destination!(wiki,item[:path]);wiki.write_file(item[:path],item[:content],committer:commit,normalize:false)
        end
      end
      plan[:remove].each { |path| wiki.delete_page(wiki.page(path),committer:commit) }
      plan.merge(commit:commit.commit)
    end
  end
end
