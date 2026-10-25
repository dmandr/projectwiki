module Precious
  module Views
    class RawNotes < Settings
      def title; 'Raw Notes'; end
      def projectbook_breadcrumbs
        [{label: 'Raw Notes', url: page_route('gollum/raw-notes')}]
      end
    end
  end
end
