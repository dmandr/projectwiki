module Precious
  module Views
    class Attachment < Layout
      attr_reader :file
      def title
        file.filename
      end
      def raw_url
        page_route(Gollum::NavigationIndex.encode_path(file.url_path))
      end
      def folder_url
        parent = ::File.dirname(file.url_path)
        parent == '.' ? overview_path : "#{overview_path}/#{Gollum::NavigationIndex.encode_path(parent)}/"
      end
      def image
        %w[.png .jpg .jpeg .gif .webp .svg .avif .bmp].include?(::File.extname(file.filename).downcase)
      end
      def pdf
        ::File.extname(file.filename).downcase == '.pdf'
      end
      def other
        !image && !pdf
      end
    end
  end
end
