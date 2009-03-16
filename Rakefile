require 'rubygems'
require 'rake'
require 'rake/testtask'
require 'rake/rdoctask'

desc 'Default: run unit tests.'
task :default => :test

desc 'Generate RDoc documentation for the Graffic plugin.'
Rake::RDocTask.new(:rdoc) do |rdoc|
  rdoc.rdoc_files.include('README.rdoc', 'MIT-LICENSE', 'CHANGELOG.rdoc').include('lib/**/*.rb')
  
  rdoc.main = "README.rdoc" # page to start on
  rdoc.title = "Graffic documentation"
  
  rdoc.rdoc_dir = 'doc' # rdoc output folder
  rdoc.options << '--inline-source' << '--charset=UTF-8'
  rdoc.options << '--webcvs=http://github.com/jeremyboles/graffic/tree/master/'
end

desc %{Update ".manifest" with the latest list of project filenames.}
task :manifest do
  list = `git ls-files --full-name --exclude=*.gemspec --exclude=.*`.chomp.split("\n")
  
  if spec_file = Dir['*.gemspec'].first
    spec = File.read spec_file
    spec.gsub! /^(\s* s.(test_)?files \s* = \s* )( \[ [^\]]* \] | %w\( [^)]* \) )/mx do
      assignment = $1
      bunch = $2 ? list.grep(/^test\//) : list
      '%s%%w(%s)' % [assignment, bunch.join(' ')]
    end
      
    File.open(spec_file, 'w') { |f| f << spec }
  end
  File.open('.manifest', 'w') { |f| f << list.join("\n") }
end

desc 'Test the graffic plugin.'
Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.pattern = 'test/**/*_test.rb'
  t.verbose = true
end
 
desc 'Generate documentation for the graffic plugin.'
Rake::RDocTask.new(:rdoc) do |rdoc|
  rdoc.rdoc_dir = 'rdoc'
  rdoc.title    = 'Graffic'
  rdoc.options << '--line-numbers' << '--inline-source'
  rdoc.rdoc_files.include('README.rdoc')
  rdoc.rdoc_files.include('lib/**/*.rb')
end