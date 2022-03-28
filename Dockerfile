FROM alpine:3.14
ENV TZ=Asia/Hong_Kong

RUN apk add --no-cache unrar p7zip ruby ruby-nokogiri ruby-bundler ruby-unf_ext ruby-json tzdata

WORKDIR /app

COPY Gemfile ./
RUN bundle install --jobs=3 --no-cache --without=dev
COPY *.rb ./

VOLUME /data

CMD ["bundle", "exec", "ruby", "./subs.rb", "-d", "/data"]
