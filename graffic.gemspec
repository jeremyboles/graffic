Gem::Specification.new do |s|
  s.name    = 'graffic'
  s.version = '0.2.7'
  s.date    = '2009-03-19'
  
  s.summary = "Image asset handing for ActiveRecord and Rails"
  s.description = "Graffic is an ActiveRecord class that helps you work with and attach images to other ActiveRecord records."
  
  s.authors  = ['Jeremy Boles']
  s.email    = 'jeremy@jeremyboles.com'
  s.homepage = 'http://github.com/jeremyboles/graffic/wikis'
  
  s.has_rdoc = true
  s.rdoc_options = ['--main', 'README.rdoc']
  s.rdoc_options << '--inline-source' << '--charset=UTF-8'
  s.extra_rdoc_files = ['README.rdoc', 'MIT-LICENSE', 'CHANGELOG.rdoc']
  
  s.files = %w(CHANGELOG.rdoc MIT-LICENSE README.rdoc Rakefile generators/graffic/graffic_generator.rb generators/graffic/templates/migration.rb init.rb lib/graffic.rb lib/graffic/aws.rb lib/graffic/ext.rb lib/graffic/view_helpers.rb tasks/graffic_tasks.rake test/graffic_test.rb test/test_helper.rb uninstall.rb)
  s.test_files = %w(test/graffic_test.rb test/test_helper.rb)
  
  s.add_dependency 'right_aws', '1.10.0'
  s.add_dependency 'rmagick', '2.9.1'
end