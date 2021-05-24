FROM alpine:3.13

RUN apk add --no-cache unrar p7zip ruby ruby-nokogiri ruby-bundler ruby-unf_ext ruby-json

WORKDIR /app

COPY Gemfile ./
RUN bundle install --jobs=3
COPY *.rb .

VOLUME /data

CMD ["bundle", "exec", "ruby", "./subs.rb", "-d", "/data"]
