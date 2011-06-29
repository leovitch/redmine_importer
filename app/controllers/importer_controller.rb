require 'fastercsv'
require 'tempfile'
require 'iconv'

class MultipleIssuesForUniqueValue < Exception
end

class NoIssueForUniqueValue < Exception
end

class ImporterController < ApplicationController
  unloadable
  
  before_filter :find_project

  ISSUE_ATTRS = [:id, :subject, :assigned_to, :fixed_version,
    :author, :description, :category, :priority, :tracker, :status,
    :start_date, :due_date, :done_ratio, :estimated_hours,
    :parent_issue, :watchers ]
  
  def index
  end

  def match
    # Delete existing iip to ensure there can't be two iips for a user
    ImportInProgress.delete_all(["user_id = ?",User.current.id])
    # save import-in-progress data
    iip = ImportInProgress.find_or_create_by_user_id(User.current.id)
    iip.quote_char = params[:wrapper]
    iip.col_sep = params[:splitter]
    iip.encoding = params[:encoding]
    iip.created = Time.new
    iip.csv_data = params[:file].read
    iip.save
    
    # Put the timestamp in the params to detect
    # users with two imports in progress
    @import_timestamp = iip.created.strftime("%Y-%m-%d %H:%M:%S")
    @original_filename = params[:file].original_filename
    
    # display sample
    sample_count = 5
    i = 0
    @samples = []
    
    # transcode the ANSI format to UTF8 using iconv
    if (iip.encoding == "A" )
    	ansi2utf8(iip)
    end
    
    FasterCSV.new(iip.csv_data, {:headers=>true,
    :encoding=>iip.encoding, :quote_char=>iip.quote_char, :col_sep=>iip.col_sep}).each do |row|
      @samples[i] = row
     
      i += 1
      if i >= sample_count
        break
      end
    end # do
    
    if @samples.size > 0
      @headers = @samples[0].headers
    end
    
    # fields
    @attrs = Array.new
    ISSUE_ATTRS.each do |attr|
      #@attrs.push([l_has_string?("field_#{attr}".to_sym) ? l("field_#{attr}".to_sym) : attr.to_s.humanize, attr])
      @attrs.push([l_or_humanize(attr, :prefix=>"field_"), attr])
    end
    @project.all_issue_custom_fields.each do |cfield|
      @attrs.push([cfield.name, cfield.name])
    end
    IssueRelation::TYPES.each_pair do |rtype, rinfo|
      @attrs.push([l_or_humanize(rinfo[:name]),rtype])
    end
    @attrs.sort!
  end
  
  # Returns the issue object associated with the given value of the given attribute.
  # Raises NoIssueForUniqueValue if not found or MultipleIssuesForUniqueValue
  def issue_for_unique_attr(unique_attr, attr_value)
    if @issue_by_unique_attr.has_key?(attr_value)
      return @issue_by_unique_attr[attr_value]
    end
    if unique_attr == "id"
      issues = [Issue.find_by_id(attr_value)]
    else
      query = Query.new(:name => "_importer", :project => @project)
      query.add_filter("status_id", "*", [1])
      query.add_filter(unique_attr, "=", [attr_value])

      issues = Issue.find :all, :conditions => query.statement, :limit => 2, :include => [ :assigned_to, :status, :tracker, :project, :priority, :category, :fixed_version ]
    end
    
    if issues.size > 1
      flash[:warning] = "Unique field #{unique_attr}  with value '#{attr_value}' has duplicate record"
      @failed_count += 1
      @failed_issues[@handle_count + 1] = row
      raise MultipleIssuesForUniqueValue, "Unique field #{unique_attr}  with value '#{attr_value}' has duplicate record"
    else
      if issues.size == 0
        raise NoIssueForUniqueValue, "No issue with #{unique_attr} of '#{attr_value}' found"
      end
      issues.first
    end
  end

  def result
    @handle_count = 0
    @update_count = 0
    @skip_count = 0
    @failed_count = 0
    @failed_issues = Hash.new
    @affect_projects_issues = Hash.new
    # This is a cache of previously inserted issues indexed by the value
    # the user provided in the unique column
    @issue_by_unique_attr = Hash.new
    
    # Retrieve saved import data
    iip = ImportInProgress.find_by_user_id(User.current.id)
    if iip == nil
      flash[:error] = "No import is currently in progress"
      return
    end
    if iip.created.strftime("%Y-%m-%d %H:%M:%S") != params[:import_timestamp]
      flash[:error] = "You seem to have started another import " \
          "since starting this one. " \
          "This import cannot be completed"
      return
    end
    

    
    default_tracker = params[:default_tracker]
    update_issue = params[:update_issue]
    unique_field = params[:unique_field].empty? ? nil : params[:unique_field]
    journal_field = params[:journal_field]
    update_other_project = params[:update_other_project]
    ignore_non_exist = params[:ignore_non_exist]
    fields_map = params[:fields_map]
    send_emails = params[:send_emails]
    add_categories = params[:add_categories]
    add_versions = params[:add_versions]
    unique_attr = fields_map[unique_field]
    unique_attr_checked = false  # Used to optimize some work that has to happen inside the loop   

    # attrs_map is fields_map's invert
    attrs_map = fields_map.invert

    # check params
    unique_error = nil
    if update_issue
      unique_error = l(:text_rmi_specify_unique_field_for_update)
    elsif attrs_map["parent_issue"] != nil
      unique_error = l(:text_rmi_specify_unique_field_for_column,:column => l(:field_parent_issue))
    else
      IssueRelation::TYPES.each_key do |rtype|
        if attrs_map[rtype]
          unique_error = l(:text_rmi_specify_unique_field_for_column,:column => l("label_#{rtype}".to_sym))
          break
        end
      end
    end
    if unique_error && unique_attr == nil
      flash[:error] = unique_error
      return
    end
		
    # transcode the ANSI format to UTF8 using iconv
    if (iip.encoding == "A" )
    	ansi2utf8(iip)
    end

    FasterCSV.new(iip.csv_data, {:headers=>true, :encoding=>iip.encoding, 
        :quote_char=>iip.quote_char, :col_sep=>iip.col_sep}).each do |row|

      project = Project.find_by_name(row[attrs_map["project"]])
      if !project
        project = @project
      end
      tracker = Tracker.find_by_name(row[attrs_map["tracker"]])
      status = IssueStatus.find_by_name(row[attrs_map["status"]])
      author = attrs_map["author"] ? User.find_by_login(row[attrs_map["author"]]) : User.current
      priority = Enumeration.find_by_name(row[attrs_map["priority"]])
      category_name = row[attrs_map["category"]]
      category = IssueCategory.find_by_name(category_name)
      if (!category) && category_name && category_name.length > 0 && add_categories
        category = project.issue_categories.build(:name => category_name)
        category.save
      end
      assigned_to = row[attrs_map["assigned_to"]] != nil ? User.find_by_login(row[attrs_map["assigned_to"]]) : nil
      fixed_version_name = row[attrs_map["fixed_version"]]
      fixed_version = Version.find_by_name(fixed_version_name)
      if (!fixed_version) && fixed_version_name && fixed_version_name.length > 0 && add_versions
        fixed_version = project.versions.build(:name=>fixed_version_name)
        fixed_version.save
      end
      watchers = row[attrs_map["watchers"]]
      # new issue or find exists one
      issue = Issue.new
      journal = nil
      issue.project_id = project != nil ? project.id : @project.id
      issue.tracker_id = tracker != nil ? tracker.id : default_tracker
      issue.author_id = author != nil ? author.id : User.current.id

      # trnaslate unique_attr if it's a custom field -- only on the first issue
      if !unique_attr_checked
        if unique_field && !ISSUE_ATTRS.include?(unique_attr.to_sym)
          issue.available_custom_fields.each do |cf|
            if cf.name == unique_attr
              unique_attr = "cf_#{cf.id}"
              break
            end
          end
        end
        unique_attr_checked = true
      end

      if update_issue
        begin
          issue = issue_for_unique_attr(unique_attr,row[unique_field])
          
          # ignore other project's issue or not
          if issue.project_id != @project.id && !update_other_project
            @skip_count += 1
            next
          end
          
          # ignore closed issue except reopen
          if issue.status.is_closed?
            if status == nil || status.is_closed?
              @skip_count += 1
              next
            end
          end
          
          # init journal
          note = row[journal_field] || ''
          journal = issue.init_journal(author || User.current, 
            note || '')
            
          @update_count += 1
          
        rescue NoIssueForUniqueValue
          if ignore_non_exist
            @skip_count += 1
            next
          end
          
        rescue MultipleIssuesForUniqueValue
          break
        end
      end
    
      # project affect
      if project == nil
        project = Project.find_by_id(issue.project_id)
      end
      @affect_projects_issues.has_key?(project.name) ?
        @affect_projects_issues[project.name] += 1 : @affect_projects_issues[project.name] = 1

      # required attributes
      issue.status_id = status != nil ? status.id : issue.status_id
      issue.priority_id = priority != nil ? priority.id : issue.priority_id
      issue.subject = row[attrs_map["subject"]] || issue.subject
      
      # optional attributes
      issue.description = row[attrs_map["description"]] || issue.description
      issue.category_id = category != nil ? category.id : issue.category_id
      issue.start_date = row[attrs_map["start_date"]] || issue.start_date
      issue.due_date = row[attrs_map["due_date"]] || issue.due_date
      issue.assigned_to_id = assigned_to != nil ? assigned_to.id : issue.assigned_to_id
      issue.fixed_version_id = fixed_version != nil ? fixed_version.id : issue.fixed_version_id
      issue.done_ratio = row[attrs_map["done_ratio"]] || issue.done_ratio
      issue.estimated_hours = row[attrs_map["estimated_hours"]] || issue.estimated_hours

      # parent issues
      begin
        if row[attrs_map["parent_issue"]] != nil
          issue.parent_issue_id = issue_for_unique_attr(unique_attr,row[attrs_map["parent_issue"]]).id
        end
      rescue NoIssueForUniqueValue
        if ignore_non_exist
          @skip_count += 1
          next
        end
      rescue MultipleIssuesForUniqueValue
        break
      end

      # custom fields
      issue.custom_field_values = issue.available_custom_fields.inject({}) do |h, c|
        if value = row[attrs_map[c.name]]
          h[c.id] = value
        end
        h
      end
      
      # watchers
      if watchers
        addable_watcher_users = issue.addable_watcher_users
        watchers.split(',').each do |watcher|
          watcher_user = User.find_by_login(watcher)
          if (!watcher_user) || (issue.watcher_users.include?(watcher_user))
            next
          end
          if addable_watcher_users.include?(watcher_user)
            issue.add_watcher(watcher_user)
          end
        end
      end

      if (!issue.save)
        # 记录错误
        @failed_count += 1
        @failed_issues[@handle_count + 1] = row
      else
        if unique_field
          @issue_by_unique_attr[row[unique_field]] = issue
        end
        
        if send_emails
          if update_issue
            if Setting.notified_events.include?('issue_updated')
              Mailer.deliver_issue_edit(issue.current_journal)
            end
          else
            if Setting.notified_events.include?('issue_added')
              Mailer.deliver_issue_add(issue)
            end
          end
        end

        # Issue relations
        begin
          IssueRelation::TYPES.each_pair do |rtype, rinfo|
            if !row[attrs_map[rtype]]
              next
            end
            other_issue = issue_for_unique_attr(unique_attr,row[attrs_map[rtype]])
            relations = issue.relations.select { |r| (r.other_issue(issue).id == other_issue.id) && (r.relation_type_for(issue) == rtype) }
            if relations.length == 0
              relation = IssueRelation.new( :issue_from => issue, :issue_to => other_issue, :relation_type => rtype )
              relation.save
            end
          end
        rescue NoIssueForUniqueValue
          if ignore_non_exist
            @skip_count += 1
            next
          end
        rescue MultipleIssuesForUniqueValue
          break
        end
      end
  
      if journal
        journal
      end
      
      @handle_count += 1
    end # do
    
    if @failed_issues.size > 0
      @failed_issues = @failed_issues.sort
      @headers = @failed_issues[0][1].headers
    end
    
    # Clean up after ourselves
    iip.delete
    
    # Garbage prevention: clean up iips older than 3 days
    ImportInProgress.delete_all(["created < ?",Time.new - 3*24*60*60])
  end

private
	
	# converts the ImportInProgrsse csv data from ansi to utf8
	def ansi2utf8(importip)
		converter = Iconv.new('UTF-8','CP1252')
		importip.csv_data = converter.iconv(importip.csv_data)
		#changing the encoding tag : U for UTF8
		importip.encoding = "U"
	end

  def find_project
    @project = Project.find(params[:project_id])
  end
  
end
