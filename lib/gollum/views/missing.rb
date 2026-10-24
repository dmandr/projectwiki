module Precious
  module Views
    class Missing < Layout
      attr_reader :missing_path, :missing_title
      def title; 'Document not found'; end
    end
  end
end
