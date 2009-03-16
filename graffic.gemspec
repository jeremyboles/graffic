Gem::Specification.new do |s|
  s.name    = 'graffic'
  s.version = '0.1.0'
  s.date    = '2009-03-16'
  
  s.summary = "Image asset handing for ActiveRecord and Rails"
  s.description = "Graffic is an ActiveRecord class that helps you work with and attach images to other ActiveRecord records."
  
  s.authors  = ['Jeremy Boles']
  s.email    = 'jeremy@jeremyboles.com'
  s.homepage = 'http://github.com/jeremyboles/graffic/wikis'
  
  s.has_rdoc = true
  s.rdoc_options = ['--main', 'README.rdoc']
  s.rdoc_options << '--inline-source' << '--charset=UTF-8'
  s.extra_rdoc_files = ['README.rdoc', 'LICENSE', 'CHANGELOG.rdoc']
  
  s.files = %w(MIT-LICENSE README Rakefile init.rb install.rb lib/graffic.rb tasks/graffic_tasks.rake test/graffic_test.rb test/test_helper.rb uninstall.rb)
  s.test_files = %w(test/graffic_test.rb test/test_helper.rb)
end