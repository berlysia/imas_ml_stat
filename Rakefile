require './refresh.rb'

task :get_cardlist do
  get_cardlist
end

task :parse_cardlist do
  parse_cardlist
end

task :create_csv do
  create_csv
end

task :commit do
  `git add --all`
  `git commit -m 'update'`
  `git push`
end

task :all => [:get_cardlist, :parse_cardlist, :create_csv, :commit]
