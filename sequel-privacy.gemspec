# frozen_string_literal: true

require_relative 'lib/sequel/privacy/version'

Gem::Specification.new do |spec|
  spec.name = 'sequel-privacy'
  spec.version = Sequel::Privacy::VERSION
  spec.authors = ['Austin Bales']
  spec.email = ['arbales@gmail.com']

  spec.summary = 'Privacy enforcement plugin for Sequel models'
  spec.description = 'A Sequel plugin that provides declarative privacy policies ' \
                     'and automatic enforcement at field access and query boundaries.'
  spec.homepage = 'https://github.com/arbales/sequel-privacy'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.glob('lib/**/*') + Dir.glob('rbi/**/*.rbi') + %w[README.md CHANGELOG.md LICENSE.txt]
  spec.require_paths = ['lib']

  spec.add_dependency 'sequel', '~> 5.0'
  spec.add_dependency 'sorbet-runtime', '~> 0.5'

  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'sqlite3', '~> 1.4'
  spec.add_development_dependency 'sorbet', '~> 0.5'
  spec.add_development_dependency 'tapioca', '~> 0.17'
end
