FROM alpine:3.13

RUN apk add --no-cache unrar p7zip ruby ruby-nokogiri ruby-bundler ruby-unf_ext

WORKDIR /app

COPY Gemfile ./
RUN bundle install --jobs=3
COPY subfinder.rb .

VOLUME /data

CMD ["bundle", "exec", "ruby", "./subfinder.rb", "-d", "/data"]
