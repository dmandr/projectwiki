module Precious
  module Views
    class Tasks < Settings
      def title; 'TODO'; end
      def projectbook_breadcrumbs
        [{label: 'TODO', url: page_route('gollum/tasks')}]
      end
    end
  end
end
