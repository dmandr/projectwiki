FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914 AS editor
WORKDIR /build
COPY projectbook/editor/package.json projectbook/editor/package-lock.json ./
RUN npm ci
COPY projectbook/editor/build.mjs ./
COPY projectbook/editor/src ./src
RUN npm run build

# Current Gollum sources initialize SassC even with precompiled assets.
# Compile explicit additional versions against exactly the same Ruby/Alpine runtime.
FROM gollumwiki/gollum:6.1.0@sha256:05f23e49ba475169ef5d42356428d9762e88c94396fd747b0825bddb628141de AS native
USER root
RUN apk add --no-cache build-base \
    && gem install ffi --version 1.17.2 --platform ruby --ignore-dependencies --no-document \
    && gem install sassc --version 2.4.0 --ignore-dependencies --no-document

# The app is THIS checkout; no Git checkout or credentials enter the image.
FROM gollumwiki/gollum:6.1.0@sha256:05f23e49ba475169ef5d42356428d9762e88c94396fd747b0825bddb628141de
USER root
WORKDIR /opt/projectbook-source
RUN apk add --no-cache poppler-utils nodejs
COPY --from=native /usr/local/bundle/ /usr/local/bundle/
RUN gem install simpleidn:0.3.0 hana:1.3.7 json_schemer:2.5.0 mcp:1.8.1 jwt:3.3.0 --ignore-dependencies --no-document
COPY . .
RUN ruby projectbook/verify-runtime.rb \
    && gem build gollum.gemspec \
    && gem install --local --force --ignore-dependencies --no-document ./gollum-*.gem \
    && rm ./gollum-*.gem \
    && ruby -e 'require "gollum/app"; puts "Gollum runtime loaded"'
COPY projectbook/config.rb /experiment/config.rb
COPY projectbook/templates /experiment/templates
COPY projectbook/extensions /experiment/extensions
COPY --from=editor /build/dist /experiment/editor/dist
RUN mkdir -p /var/lib/projectbook && chown www-data:www-data /var/lib/projectbook
USER www-data
WORKDIR /wiki
HEALTHCHECK --interval=30s --timeout=25s --start-period=30s --retries=3 \
  CMD ruby -rnet/http -e 'r = Net::HTTP.start("127.0.0.1", 4567, nil, nil, open_timeout: 2, read_timeout: 20) { |h| h.get("/gollum/overview") }; exit(r.code.to_i == 200 ? 0 : 1)'
ENTRYPOINT ["gollum"]
CMD ["/wiki", "--host", "0.0.0.0", "--port", "4567", "--config", "/experiment/config.rb"]
