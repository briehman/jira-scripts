#!/usr/bin/env ruby

require 'csv'
require 'dotenv'
require 'getoptlong'
require 'json'
require 'restclient'
require 'yaml'

def parse_params(params)
  opts = GetoptLong.new(
    [ '--active', '-a', GetoptLong::NO_ARGUMENT ],
    [ '--board', '-b', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--environment', '-e', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--file', '-f', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--debug', '-d', GetoptLong::NO_ARGUMENT ],
    [ '--dump', GetoptLong::NO_ARGUMENT ],
    [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
    [ '--offline', GetoptLong::NO_ARGUMENT ],
    [ '--since', '-s', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--until', '-u', GetoptLong::REQUIRED_ARGUMENT ],
  )

  opts.each do |opt, arg|
    case opt
    when '--help'
      puts <<-EOF
sprint-metrics [OPTION] ...

Summary:

Generate Sprint Metrics around committed and uncommitted tickets. This requires
that tickets have a custom field to indicate the date a ticket has been
committed to be completed by the team. It also needs a field to indicate the
number of story points assigned to the field.

Setup:

This script requires configuration file entry to provide details about the
JIRA host being used and the names of the custom fields noted above. The
default location for the .env file is #{params[:env]}.  The following variables
should be set in that file:

JIRA_URL - The JIRA base URL such as https://jira.companyname.com
JIRA_USERNAME - The username for the JIRA account
JIRA_PASSWWORD - The password or token for the JIRA account
JIRA_COMMITTED_DATE_CUSTOM_FIELD - Custom field name for committed date
JIRA_STORY_POINTS_CUSTOM_FIELD - Custom field name for story points

Flags:
--active, -a
  Generate stats for the active sprint. This is the default stats behavior.

--board 'Board Name', -b 'Board Name'
  Use the provided board name to generate stats.

-d, --debug
  Enable debug output

--dump
  Dump the JSON output to files in the current directory so they can be used
  with --offline mode.

--environment /path/to/file, -e /path/to/file
  Path for the .env file to load that will contain the appropriate required
  variables.

--file /path/to/file, -f /path/to/file
  Output file path for CSV data. If not specified, CSV data is not written.

-h, --help
  show help

--offline
  Use the dump files in the current directory generated using --dump instead
  of actually querying JIRA.

--since YYYY-MM-DD, -s YYYY-MM-DD
  Generate stats for sprints starting on or after the provided date.

--until YYYY-MM-DD, -u YYYY-MM-DD
  Generate stats for sprints ending on or before the provided date.

      EOF
      exit 1
    when '--active'
      params[:active] = true
    when '--board'
      params[:board] = arg
    when '--debug'
      params[:debug] = true
    when '--dump'
      params[:dump] = true
    when '--environment'
      params[:env] = arg
    when '--file'
      params[:file] = arg
    when '--jira'
      params[:jira] = arg
    when '--offline'
      params[:offline] = true
    when '--since'
      params[:since] = Date.strptime(arg, '%Y-%m-%d').to_datetime
    when '--until'
      params[:until] = Date.strptime(arg, '%Y-%m-%d').to_datetime
    end
  end

  unless params[:board] then
    STDERR.puts "ERROR: Must supply a JIRA board name using -b or --board."
    exit 1
  end

  if params[:until] and not params[:since] then
    STDERR.puts "ERROR: Must supply a 'since' date if using 'until'."
    exit 1
  end

  params
end

def jira_board_api(params, path = '')
  "#{ENV['JIRA_URL']}//rest/agile/1.0/board#{path}"
end

def query_sprint_issues(params, board_id, sprint)

  story_points_field = ENV['JIRA_STORY_POINTS_CUSTOM_FIELD']
  due_date_field = ENV['JIRA_COMMITTED_DATE_CUSTOM_FIELD']

  issue_query_fields = %W(id key created updated summary status resolution resolutiondate labels issuetype #{story_points_field} #{due_date_field})

  start = 0
  max_results = 500
  total = 8000
  all_issues = []
  reported_total = false

  while start < total
    output = RestClient::Request.execute(
      :method => :get,
      :url => jira_board_api(params, "/#{board_id}/sprint/#{sprint[:id]}/issue"),
      :user => $username,
      :password => $password,
      :headers =>{
        :accept => :json,
        :content_type => :json,
        :params => {
          :startAt => start,
          :maxResults => max_results,
          :fields => issue_query_fields,
        }
      },
    )

    issues = JSON.parse(output, :symbolize_names => true)
    total = issues[:total]
    reported_total = true
    start += max_results

    found_issues = issues[:issues].select { |issue| issue[:fields][:issuetype][:subtask] == false }.map do |issue|
      issue_obj = {
        :id => issue[:id],
        :key => issue[:key],
        :summary => issue[:fields][:summary],
        :status => issue[:fields][:status][:name],
        :resolution => issue[:fields][:resolution].nil? ? nil : issue[:fields][:resolution][:name],
        :commitment_date => issue[:fields][due_date_field.to_sym].nil? ? nil : DateTime.strptime(issue[:fields][due_date_field.to_sym], '%Y-%m-%d'),
        :story_points => issue[:fields][story_points_field.to_sym],
        :bucket => issue[:fields][:labels].include?('Project') ? :project : issue[:fields][:labels].include?('sustainability') ? :sustainability : :bugs_improvements,
        :resolution_date => issue[:fields][:resolutiondate].nil? ? nil : DateTime.strptime(issue[:fields][:resolutiondate], '%Y-%m-%dT%H:%M:%S'),
      }

      issue_obj
    end

    unless found_issues.empty?
      all_issues.push(found_issues)
    end
  end

  all_issues.flatten
end

def get_board_id(params, name)
  board_json = JSON.parse(RestClient::Request.execute(
    :method => :get,
    :url => jira_board_api(params),
    :user => $username,
    :password => $password,
    :headers =>{
      :content_type => :json,
      :params => {
        :name => name
      }
    },
  ))

  board_json['values'][0]['id']
end

def get_active_sprint(params, board_id)
  sprint_json = JSON.parse(RestClient::Request.execute(
    :method => :get,
    :url => jira_board_api(params, "/#{board_id}/sprint"),
    :user => $username,
    :password => $password,
    :headers =>{
      :accept => :json,
      :content_type => :json,
      :params => {
        :state => 'active'
      }
    },
  ))

  if params[:intellx]
    selected_sprint = sprint_json['values'][0]
  else
    selected_sprint = sprint_json['values'].select { |sprint|
      sprint['originBoardId'] == board_id
    }[0]
  end

  convert_sprint(selected_sprint)
end

def convert_sprint(chosen_sprint)
  {
    :id => chosen_sprint['id'],
    :name => chosen_sprint['name'],
    :start_date => DateTime.strptime(chosen_sprint['startDate'], '%Y-%m-%dT%H:%M:%S'),
    :end_date => DateTime.strptime(chosen_sprint['endDate'], '%Y-%m-%dT%H:%M:%S'),
  }
end

def get_sprints_between(params, board_id)
  is_last = false
  start = 0
  all_sprints = []

  while !is_last
    sprints = JSON.parse(RestClient::Request.execute(
      :method => :get,
      :url => jira_board_api(params, "/#{board_id}/sprint"),
      :user => $username,
      :password => $password,
      :headers =>{
        :accept => :json,
        :content_type => :json,
        :params => {
          :startAt => start
        }
      },
    ), :symbolize_names => true)

    is_last = sprints[:isLast]
    start += sprints[:values].size

    found_sprints = sprints[:values].map do |sprint|
      {
        :id => sprint[:id],
        :name => sprint[:name],
        :state => sprint[:state],
        :start_date => sprint[:startDate].nil? ? nil : DateTime.strptime(sprint[:startDate], '%Y-%m-%dT%H:%M:%S'),
        :end_date => sprint[:endDate].nil? ? nil : DateTime.strptime(sprint[:endDate], '%Y-%m-%dT%H:%M:%S'),
        :origin_board_id => sprint[:originBoardId],
      }
    end

    unless found_sprints.empty?
      all_sprints.push(found_sprints)
    end

  end

  all_sprints.flatten!

  all_sprints.select { |sprint|
    sprint[:origin_board_id] == board_id and sprint[:start_date] and sprint[:start_date] >= params[:since] and sprint[:end_date] <= params[:until]
  }.sort_by { |sprint|
    sprint[:start_date]
  }
end

def get_sprint_issues(params, board_id, sprint)
  dump_file = "issues.#{sprint[:id]}.dump"
  if params[:offline]
    YAML.load(File.read(dump_file))
  else
    issues = query_sprint_issues(params, board_id, sprint)

    issues = issues.map { |issue|
      issue[:completed_in_sprint] = (issue[:resolution_date] && issue[:resolution_date] <= sprint[:end_date])
      issue
    }

    if params[:dump]
      File.write(dump_file, YAML.dump(issues))
    end

    issues
  end
end

def get_points(issues)
  issues.map { |i| i[:story_points].nil? ? 0 : i[:story_points] }.reduce(0, :+)
end

def generate_stats(title, issues, stats_lambda = nil)
  completed = issues.select { |issue| issue[:completed_in_sprint] }
  incomplete = issues.select { |issue| !issue[:completed_in_sprint] }

  stats = {
    :title => title,
    :stories => {
      :attempted => issues,
      :completed => completed,
    },
    :points => {
      :attempted => get_points(issues),
      :completed => get_points(completed),
    }
  }
  if stats_lambda
    stats_lambda.(stats)
  end
  stats
end

def print_stats(stats, print_lambda = nil)
  puts "#{stats[:title]}:"
  puts "  #{stats[:stories][:attempted].size} Stories Attempted"
  puts "  #{stats[:stories][:completed].size} Stories Completed"
  puts "  #{stats[:points][:attempted]} Points Attempted"
  puts "  #{stats[:points][:completed]} Points Completed"
  if print_lambda
    print_lambda.(stats)
  end
  puts
end

def get_stats(params, board_id, sprint)
  issues = get_sprint_issues(params, board_id, sprint)

  committed, uncommitted  = issues.partition { |issue|
    issue[:commitment_date] != nil && issue[:commitment_date] <= sprint[:end_date]
  }

  committed.map { |issue|
    issue[:missed] = !issue[:completed_in_sprint]
  }

  {
    :sprint => sprint,
    :total => generate_stats('Total', issues, -> (stats) {
      stats[:commitment_percentage] = (1.0 * committed.size / issues.size * 100).round(2)
    }),
    :committed => generate_stats('Committed', committed, -> (stats) {
      stats[:commitment] = {
        :percent => (1.0 * committed.size / issues.size * 100).round(2),
        :accuracy => (1.0 * stats[:stories][:completed].size / committed.size * 100).round(2),
        :missed => committed.select { |i| i[:missed ] }
      }
    }),
    :uncommitted => generate_stats('Uncommitted', uncommitted),
    :buckets => {
      :project => generate_stats('Project', issues.select { |i| i[:bucket] == :project }),
      :bugs_improvements => generate_stats('Bugs / Improvements', issues.select { |i| i[:bucket] == :bugs_improvements }),
      :sustainability => generate_stats('Sustainability', issues.select { |i| i[:bucket] == :sustainability }),
    },
  }
end

def print_summary(stats)
  sprint = stats[:sprint]

  puts '-' * 70
  puts "#{sprint[:name]} - #{sprint[:start_date].to_date} - #{sprint[:end_date].to_date}"

  print_stats(stats[:total], -> (stats) {
    puts "  Commitment Percentage #{stats[:commitment_percentage]}"
  })

  puts '-' * 40
  print_stats(stats[:committed], -> (stats) {
    puts "  #{stats[:commitment][:accuracy]}% Accuracy"

    missed = stats[:commitment][:missed].sort_by { |i| [i[:commitment_date], i[:key]] }

    if !missed.empty?
      missed_tickets = missed.map { |i|
        "#{i[:commitment_date].to_s.split('T')[0]} - #{i[:story_points]} pts - #{i[:key]} - #{i[:summary]}"
      }.join("\n    ")
      puts "  Missed:\n    #{missed_tickets}"
    end
  })
  print_stats(stats[:uncommitted])

  puts '-' * 40
  print_stats(stats[:buckets][:project])
  print_stats(stats[:buckets][:bugs_improvements])
  print_stats(stats[:buckets][:sustainability])
end

def get_sprints(params, board_id)
  dump_file = 'sprints.dump'

  if params[:offline]
    YAML.load(File.read(dump_file))
  else
    if params[:since]
      params[:until] ||= (Date.today + 1).to_datetime
      sprints = get_sprints_between(params, board_id)
    else
      sprints = [get_active_sprint(params, board_id)]
    end

    if params[:dump]
      File.write(dump_file, YAML.dump(sprints))
    end
    sprints
  end
end

def csv_header
  ['Stories Attempted', 'Stories Completed', 'Points Attempted', 'Points Completed']
end

def csv_data(stats)
  [stats[:stories][:attempted].size, stats[:stories][:completed].size, stats[:points][:attempted], stats[:points][:completed]]
end

def main
  default_params = {
    :env => File.join(__dir__, '.env'),
  }

  params = parse_params(default_params)

  puts "Environment file: #{params[:env]}" if params[:debug]
  Dotenv.load(params[:env])

  $url = ENV['JIRA_URL']
  $username = ENV['JIRA_USERNAME']
  $password = ENV['JIRA_PASSWORD']

  unless $username and $password
    STDERR.puts "JIRA Username and password are required. " \
      + "Be sure that the #{params[:env]} contains the appropriate values: " \
      + "JIRA_USERNAME and JIRA_PASSWORD"
    exit 1
  end

  puts params if params[:debug]

  if params[:board].to_i.to_s == params[:board]
    board_id = params[:board].to_i
  else
    board_id = get_board_id(params, params[:board])
  end

  sprints = get_sprints(params, board_id)
  sprints_stats = sprints.map do |sprint|
    get_stats(params, board_id, sprint)
  end

  sprints_stats.each do |sprints_stat|
    print_summary(sprints_stat)
  end

  if params[:file]
    CSV.open(params[:file], 'w') do |csv|

      header_size = csv_header.size
      # TODO - need to define this outside the stats so it's accessible
      group_names = ['Total', 'Committed', 'Project', 'Bugs / Improvements', 'Sustainability']
      csv << ['', '', '', '', group_names.map { |name| [name].concat([''] * (header_size - 1)) }].flatten
      csv << ['Sprint Name', 'Sprint Ending', 'Commitment %', 'Commitment Delivery %', (csv_header * group_names.size)].flatten

      sprints_stats.reverse.each do |sprint_stat|
        data = [
          csv_data(sprint_stat[:total]),
          csv_data(sprint_stat[:committed]),
          csv_data(sprint_stat[:buckets][:project]),
          csv_data(sprint_stat[:buckets][:bugs_improvements]),
          csv_data(sprint_stat[:buckets][:sustainability]),
        ]

        csv << [sprint_stat[:sprint][:name],
                sprint_stat[:sprint][:end_date].to_date.strftime('%-m/%-d/%Y'),
                sprint_stat[:committed][:commitment][:percent], sprint_stat[:committed][:commitment][:accuracy],
                data].flatten
      end
    end
  end
end

main
