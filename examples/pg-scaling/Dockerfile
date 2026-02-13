FROM ruby:3.3-alpine

RUN apk add --no-cache build-base libpq-dev

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test && rm -rf /usr/local/bundle/cache

COPY . .

EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
