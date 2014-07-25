# encoding : utf-8

require 'sinatra'
require "sinatra/reloader"
require 'redcarpet'
require 'logger'
require 'json'
require 'fastimage'
require 'nokogiri'
require 'date'

class User
	attr_accessor :id
	attr_accessor :name
	attr_accessor :pwd
	attr_accessor :roles

	def initialize(hash)
		@id = hash["id"]
		@name = hash["name"]
		@pwd = hash["pwd"]
		@roles = hash["roles"]
	end
end

ROLE = {
	"viewer"=> {
		"section"=>[:releasenotes],
		"url"=>["/test/*"]
	},
	"oper"=> {
		"section"=>[:oper],
		"url"=>["/mysite/blog/*"]
	},
	"sys"=> {
		"section"=>[:oper, :sys],
		"url"=>["/mysite/music/*","/hersite/comment/*"]
	}
}
  
USER = {
	"loginName1"=>['username1', 'pwd1', {
			"section"=>[:oper, :sys],
			"url"=>["/mysite/music/*","/hersite/comment/*"]
		}],
	"loginName2"=>['username2', 'pwd2', {
		"section"=>[:oper],
		"url"=>["/mysite/music/*"]
	}]
}

#this class to store all markdown file in memory
class Resource
	attr_accessor :res_pool   #store all resource in a hash map
	attr_accessor :nav_tree   #store navigation data ,generated from res_pool
	attr_accessor :release_notes #store release notes
	attr_accessor :search_data #store release notes

	def initialize
		@res_pool = {}
		@nav_tree = []
		@release_notes = []
		walk
		refresh_release
		if nav_tree.size <= 0 and @res_pool.keys.size > 0
			generate_tree_dfs(@nav_tree, @res_pool, '')
		end

		#init search data
		search_index, long_search_index, info = [], [], []
		generate_search_data_dfs(search_index, long_search_index, info, @res_pool, '')

		@search_data = "{'index': {'searchIndex': #{search_index.to_s}, 
			'longSearchIndex': #{long_search_index.to_s}, 'info': #{info.to_s}}}"
	end

	# generated data example:

	# 	{
	# 		"/systemname"=>{
	# 			"name"=>"system show name",
	# 			"page"=>"index.md",
	# 			"time"=>2014-03-14 12:30,
	# 			"content"=>"",
	# 			"/sub_path"=>{
	# 				"name"=>"sub dir name",
	# 				"page"=>"index.md",
	# 				"time"=>2014-03-14 12:30,
	# 				"content"=>"",
	# 				"/function_file.md"=>{
	# 					"name"=>"function showed name",
	# 					"page"=>"/systemname/sub_path/function_file.md",
	# 					"time"=>2014-03-14 12:30,
	# 					"content"=>"fdsfaaaaaaaaaaaaaaaaaaaaafasdddddddddddddd"
	# 				}
	# 			}
	# 		}
	# 	}
	#
	def walk(start=MD_PATH)
		Dir.foreach(start) do |item|
			path = File.join(start, item)
			if item == "." or item == ".." or item == "index.md"
				next
			elsif File.directory? path
				LOG.info("add dir #{path} failed.") unless add_file(path)
				walk(path)
			else	
				LOG.info("add file #{path} failed.") unless add_file(path)
			end
		end
	end

	# generate navigator tree
	# example data struct:
	# 	["system showed name", "/sys-path","",[
	# 		["module showed name","/sys-path/module-path","",[
	# 			["funcname 1","/sys-path/module-path/funcname.md","",[]],
	# 			["funcname 2","/sys-path/module-path/funcname2.md","",[]],
	# 			["funcname 3","/sys-path/module-path/funcname3.md","",[]]
	# 		]]
	# 	]]
	#
	def generate_tree_dfs(arr, hash, cpath='')
		hash.each do |key, value|
			temp_path = cpath + key
			temp_arr = arr
			next unless key.start_with?('/')
			
			if not key.end_with? ".md"
				temp_arr.push tree_node(temp_path)
				generate_tree_dfs(temp_arr.last[3], value, temp_path)
			else
				temp_arr.push tree_node(temp_path)
			end
		end
	end

	# generate search data example:
	# var search_data = {
	# 	'index' :{
	# 		'searchIndex' :[
	# 			FUNCATION NAME1,
	# 			FUNCATION NAME2
	# 		],
	# 		'longSearchIndex' : [
	# 			MODULE_NAME/FUNCTION NAME1,
	# 			MODULE_NAME/FUNCTION NAME2
	# 		],
	# 		'info' :[
	# 			['FUNC NAME1',
	# 			 '',
	# 			 URL_PATH,
	# 			 '',
	# 			 CONTENT
	# 			],
	# 			['FUNC NAME2',
	# 			 '',
	# 			 URL_PATH,
	# 			 '',
	# 			 CONTENT
	# 			]
	# 		]
	# 	}
	# }
	def generate_search_data_dfs(search_index, longSearchIndex, info, hash, cpath='')
		hash.each do |key, value|
			next unless key.start_with? "/"

			temp_path = cpath + "/" + value["name"]
			temp_search_index = search_index
			temp_longSearchIndex = longSearchIndex
			temp_info = info

			func_name = value["name"]
			sys_name = ''

			temp_search_index << func_name
			temp_longSearchIndex << temp_path
			temp_info << [func_name, temp_path, value['page'], sys_name, value['content'][0..50]]

			generate_search_data_dfs(temp_search_index, temp_longSearchIndex, temp_info, value, temp_path)
		end
	end

	def tree_node(key)
		node = index_arr(get_path_arr(key))

		[node["name"], key, "", []]
	end

	def index(key)
		temp = key
		if key.instance_of? String
			temp_key = key.sub('/index.md', '')
			temp = get_path_arr(temp_key)
		end

		result = index_arr(temp)
		if result["time"] < get_mtime(key)
			key = File.join(MD_PATH, key) unless key.start_with? MD_PATH
			key.sub!("index.md", '') if key.end_with? 'index.md'
			add_file(key, true)
		end

		result
	end

	def get_mtime(file)
		disk_file = MD_PATH + file unless file.start_with? MD_PATH
		disk_file = disk_file + "index.md" if File.directory? disk_file
		return nil unless File.exists? disk_file
		
		File.mtime(disk_file)
	end

	def index_arr(arr)
		arr.inject(@res_pool, :fetch)
	end

	def add_file(file, force=false)
		arr = get_path_arr(file)
		name = get_file_name(file)
		time = get_target_time(file)
		content = read_file(file)
		if name=='' or name.nil?
			return false
		end
		file += "/index.md" if File.directory? file
		file.sub!(MD_PATH, '') if file.start_with? MD_PATH

		check_path_key(arr)
		last = arr.pop
		curr = arr.inject(@res_pool, :fetch)[last]
		curr["name"] = name if (force or curr["name"].nil?)
		curr["time"] = time if (force or curr["time"].nil?)
		curr["page"] = file if (force or curr["page"].nil?)
		curr["content"] = content if (force or curr["path_content"].nil?)

		return true
	end

	def read_file(path)
		str = ''
		path += "/index.md" if File.directory? path
		return nil unless File.exists? path

		File.open(path, :encoding=>"utf-8") do |f|
			while line=f.gets
				str << line
			end
		end

		str
	end
	
	def get_file_name(file)
		file += "/index.md" if File.directory? file
		return nil unless File.exists? file

		file = File.new(file, 'r', :encoding=>"utf-8")
		line = file.gets
		if line.index("<!--").nil?
			return nil
		end
		_begin = line.index("<!--") + 4
		_end = line.index("-->")

		_arr = line[_begin... _end].strip.split(":")
		if _arr[0].strip.downcase == "path"
			return _arr[1]
		end
	end

	def get_target_time(target)
		target += "/index.md" if File.directory? target
		return nil unless File.exists? target

		File.mtime(target)
	end

	def get_path_arr(str, prefix=MD_PATH)
		arr = str.sub(prefix, '').split("/")
		arr.delete('')

		arr.map{|item| '/' + item}
	end

	def check_path_key(arr)
		curr = @res_pool

		arr.each do |i|
			curr[i] = {} if curr[i].nil?
			curr = curr[i]
		end
	end

	def split_release(full_doc)
		return [] if full_doc.nil?

		unless full_doc.index("<releasenotes>") and full_doc.index("</releasenotes>")
			return []
		end

		full_doc[full_doc.index("<releasenotes>")+14...full_doc.index("</releasenotes>")].split(/\s{2,}\n+/)
	end
	
	def get_release()
		refresh_release
		
		return release_notes
	end

	def refresh_release
		@release_notes = []
		read_atom_releases
	end

	def process_release(path)
		return get_file_name(path), split_release(read_file(path))
	end

	def split_release_item(str)
		timestr = (/\d{4}[-|\/|\s]\d{1,2}[-|\/|\s]\d{1,2}/.match(str)).to_s
		
		return timestr, str[str.index(timestr)+timestr.size..-1]
	end

	def read_atom_releases(start=MD_PATH)
		Dir.foreach(start) do |item|
			path = File.join(start, item)
			relative_path = path.sub(MD_PATH, '')
			file_name, splited_ctn = process_release(path)
			if item == "." or item == ".." or item == "index.md"
				next
			elsif File.directory? path
				# read content
				# 1.get Function name
				# 2.split release content
				# 3.store into hash table
				splited_ctn.each do |item|
					timestr, ctn = split_release_item(item)
					release_notes << [relative_path, file_name, timestr, ctn] if not ctn.nil? and ctn.strip.chomp.size > 0
				end
				read_atom_releases(path)
			else
				splited_ctn.each do |item|
					timestr, ctn = split_release_item(item)
					release_notes << [relative_path, file_name, timestr, ctn] if not ctn.nil? and ctn.strip.chomp.size > 0
				end
			end
		end
	end
end

class Utils
	class << self
		def zhtime(time)
			Time.now.strftime("%Y年%m月%d %H:%m:%S")
		end

		def read_modify_time(file)
			file.mtime
		end

		def get_image_size(image_pool, path)
			path = File.join(IMAGE_PATH, path) unless path.start_with? IMAGE_PATH
			image_pool[path] = FastImage.size(path) unless image_pool.keys.index(path)
			
			image_pool[path]
		end
	end
end

class MyRender< Redcarpet::Render::HTML
	attr_accessor :image_pool

	def initialize(hash)
		super(hash)
		@image_pool = {}
	end

	def image(link, title, alt_text)
		width, height = Utils.get_image_size(@image_pool, link)
		if width.nil? or width<=0
			return "<img title='#{title}' src='#{link}' alt='#{alt_text}' />"
		end

		width = 600 if width > 600

		str=<<DOC
		<a class="imagegroup" href="#{link}">
			<img title="#{title}" src="#{link}" width="#{width}" alt="#{alt_text}.click to view big chart." />
		</a>
DOC
		
		str
	end
end

# const define
puts "---------init begin----------"
MD_PATH = File.dirname(__FILE__)+"/public/content/"
IMAGE_PATH = File.dirname(__FILE__)+"/public/"
SITE_ROOT = "http://127.0.0.1:3000/"
LOG = Logger.new("#{File.dirname(__FILE__)}/log/app.log", 2000000)
options = {}
MD = Redcarpet::Markdown.new(MyRender.new(:with_toc_data => true), options)
MD_TOC = Redcarpet::Markdown.new(Redcarpet::Render::HTML_TOC.new(nesting_level: 3))
respool = Resource.new
respool.walk

puts "---------init end----------"

enable :sessions

get "/" do
	erb :default
end

get %r{/release(\d{4}-\d{1,2}-\d{1,2})} do
	@data = respool.get_release.select{|item| item[2] == params[:captures].first}

	erb :release
end

get %r{/release([\d]*)} do 
	rlsidx = 0
	if params[:captures].first.size == 0 or 
		params[:captures].first.nil?
		rlsidx = 0
	else
		rlsidx = params[:captures].first
	end
	
	temparr = []
	@data = []
	(respool.get_release.sort{|a, b| b[2] <=> a[2]}).each do |item|
		temparr<< item[2].strip unless temparr.index(item[2].strip)
		break if temparr.size > rlsidx.to_i + 1

		@data << item
	end

	erb :release
end

get "/index" do
	erb :index
end

get "/tree.js" do
	content_type 'application/javascript',:charset=>'utf-8'
	"var tree = " + respool.nav_tree.to_s
end

get "/search_index.js" do
	content_type 'application/javascript',:charset=>'utf-8'

	"var search_data = " + respool.search_data.to_s
end

#route handler
get "/*.md" do
	md respool.index(request.path_info)["content"].clone
end

get "/nav" do
	erb :nav
end

get "/login" do
	uname = params["uname"]
	pwd = params["pwd"]

	return "user not exists !" if USER[uname].nil?
	if USER[uname][1] == pwd.strip
		session["user"] = USER[uname]
		return "login ok."
	else
		return "pwd is not correct."
	end
end

post "/login.json" do
	puts "refer ---#{request.referer}"
	content_type 'applicaton/json',:charset=>'utf-8'
	uname = params["uname"]
	pwd = params["pwd"]

	# -1 user not exists
	# 0 successed
	# 1 pwd is not correct
	return {"code"=>-1, "content"=>nil}.to_json if USER[uname].nil?
	if USER[uname][1] == pwd.strip
		session["user"] = USER[uname]
		arr = USER[uname].clone
		arr[1]=''
		return {"code"=>0, "content"=>arr}.to_json
	else
		return {"code"=>1, "content"=>''}.to_json
	end
end

get "/logout" do
	session["user"] = nil if session["user"]
end

# error handler block
error 403 do
	'没有权限查看此页面'
end

not_found do
	'can\'t find the page'
end

error 500..510 do
	'server error'
end

before "/*" do
	if request.path_info.end_with? ".md"
		puts "can\'t view" unless can_view?(request.path_info)
	end
	redirect File.join(request.path_info,'index.md') if directory? request.path_info
	puts params
	LOG.info "#{request.ip} #{request.path_info} #{params.inspect}"
end

helpers do
	def can_view?(path)
		power = ROLE["viewer"]["url"]
		power = session["user"][2]["url"] unless session["user"].nil?
		puts "-----power-----"+power.to_s
		power.each do |item|
			puts "---regexp test---#{item} #{path}"
			return true if Regexp.new(item) =~ path
		end

		false
	end

	def directory?(str)
		File.exists? File.join(MD_PATH, str, 'index.md')
	end

	def filter_content(str)
		#TODO
		section = ROLE["viewer"]["section"]
		puts session["user"]
		section |= session["user"][2]["section"] unless session["user"].nil?
		hide_sect = all_section - section
		hide_sect.each do |item|
			str.sub!(/<#{item.to_s.strip}>(.*)<\/#{item.to_s.strip}>/m, '')
		end
 
		section.each do |item|
			str.gsub!(/<\/?#{item.to_s.strip}>/, '')
		end

		str
	end

	def all_section
		all = []
		USER.each do |key, value|
			all |= value[2]["section"]
		end

		all
	end

	def md(str, toc=true)
		str = filter_content(str)
		toc = set_content_table(MD_TOC.render(str)) if toc

		resp=<<SRC
<!DOCTYPE html
PUBLIC "-//W3C//DTD XHTML 1.0 Frameset//EN"
"http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd">    
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
<head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
    <link rel="stylesheet" href="/source/css/style.css" type="text/css" charset="utf-8" />
    <link rel="stylesheet" href="/source/css/colorbox.css" type="text/css" charset="utf-8" />
    <script src="/source/js/jquery-1.11.0.min.js" type="text/javascript" charset="utf-8"></script>
    <script type="text/javascript" src="/source/js/jquery.colorbox-min.js"></script>
	<link rel="stylesheet" href="/source/css/hl/idea.css">
	<script src="/source/js/highlight.pack.js"></script>
	<script src="/source/js/js/vex.combined.min.js"></script>
	<link rel="stylesheet" href="/source/js/css/vex.css" />
	<link rel="stylesheet" href="/source/js/css/vex-theme-plain.css" />
	<link rel="stylesheet" href="/source/js/bs/css/bootstrap.css">
    <link rel="stylesheet" href="/source/js/bs/css/bootstrap-theme.css">
     <link rel="stylesheet" href="/source/css/python.css" type="text/css" media="screen" charset="utf-8" />
    <script src="/source/js/bs/js/bootstrap.min.js"></script>
	<!--[if IE 6]>
	<style type="text/css">
		html{overflow:hidden;}
		body{height:100%;overflow:auto;}
		#header{position:absolute;}
	</style>
	<![endif]-->
	<style>
		.dropdown a{
		  color: #fff;
		}
		.dropdown a:hover{
		  text-decoration: underline;
		}
		.dropdown>a:hover{
		  text-decoration: none;
		}
	</style>
	<script type="text/javascript" charset="utf-8">
		$(function(){
			vex.defaultOptions.className = 'vex-theme-plain';
			$('pre code').each(function(i, e) {hljs.highlightBlock(e, null, true)});
			$('.dropdown-toggle').dropdown();
			$('.dropdown').hover(function() {
		        $(this).addClass('open');
		    }, function() {
		        $(this).removeClass('open');
		    });

			$(".imagegroup").colorbox({rel:'imagegroup', transition:"none", width:"95%"});
			var cancelBtn = function(){
				$('#status').empty();
				$('#status').append($("<a href='#'>Login</a>"));
				$('#status a').click(LoginBtn);
			};

			var submitBtn = function(){
				var name = $("#uname").val();
				var pwd = $("#pwd").val();
				$.post("/login.json",{uname:name,pwd:pwd},function(data, status){
					if(data["code"] == -1){
						vex.dialog.alert("用户不存在!");
						$("#uname").val("").focus();
					}
					else if(data["code"]== 0){
						loginSucc(data["content"]);
						location.reload();
					}
					else{
						$("#pwd").val("").focus();
						vex.dialog.alert("密码错误!");
					}
				}, "json");
			}

			var loginSucc = function(user){
				var ele = "<span>"+user[0]+"/<a href='#' id='logout'>Logout</a></span>";
				$("#status").empty().append($(ele));
				$("#status a").click(function(){
					$.get("/logout",function(result, status){
						if(status.toLowerCase() == 'success'){
							location.reload();
						}
					});
				});
			}

			var LoginBtn = function(){
					var str = "<input id='uname' type='text' placeholder='username'/>"+
							"<input id='pwd' type='password' placeholder='password'/>"+
							"<a href='#' id='login'>Login</a><span>/</span><a href='#' id='cancel'>Cancel</a>";
					this.remove();
					$(str).appendTo($('#status'));

					$("#cancel").click(cancelBtn);
					$("#login").click(submitBtn);
			}

			if($('#status a').text().toLowerCase()=="login"){
				$('#status a').click(LoginBtn);
			}else{
				$('#status a').click(function(){
					$.get("/logout",function(result, status){
						if(status.toLowerCase() == 'success'){
							location.reload();
						}
					});
				});
			}
		})
	</script>
    <title>#{request.path_info}</title>
</head>
<body>
	<div id="header">
	<span id="logo">:Wiki => </span>
	<div class="dropdown">
	  <a data-toggle="dropdown" href="#">Content Table</a>
	  #{toc}
	</div>
	<span id="status">#{set_status}</span>
	</div>
	<div id="content">
		#{MD.render(str)}
	</div>
</body>
</html>
SRC
	
	resp
	end

	def set_status
		if session["user"].nil?
			"<a href='#'>Login</a>"
		else
			"<span>#{session['user'][0]}/<a href='#' id='logout'>Logout</a></span>"
		end
	end

	def set_content_table(str)
		str.sub!("<ul>", "<ul class='dropdown-menu' role='menu' aria-labelledby='dLabel'>")

		str
	end
end