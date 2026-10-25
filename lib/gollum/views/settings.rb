module Precious
  module Views
    class Settings < Layout
      def title; 'Settings'; end
      def projectbook_can_create; false; end
      def projectbook_breadcrumbs
        [{label: 'Settings', url: page_route('gollum/settings')}]
      end
    end
  end
end
