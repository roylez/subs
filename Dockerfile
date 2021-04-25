FROM ruby:alpine as builder

RUN apk add --no-cache build-base libxml2-dev libxslt-dev
RUN gem install nokogiri --platform=ruby -- --use-system-libraries

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle update --bundler && bundle install --jobs=3 && rm /usr/local/bundle/cache/*

# ----
FROM ruby:alpine

RUN apk add --no-cache libxml2 libxslt unrar p7zip

WORKDIR /app

COPY --from=builder /usr/local/bundle/ /usr/local/bundle/
COPY --from=builder /app/ ./
COPY subfinder.rb .

VOLUME /data

CMD ["bundle", "exec", "ruby", "./subfinder.rb", "-d", "/data"]
