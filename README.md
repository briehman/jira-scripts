JIRA Scripts
============

Setup
-----
Run `bundle install` to install the necessary gems

Sprint Metrics
--------------
Get the metrics for the current sprint:

    ./sprint-metrics.rb -b "Team Board"

Get the metrics for the current sprint and print to CSV:

    ./sprint-metrics.rb -b "Team Board" -f out.csv

Get the metrics for the multiple sprints:

    ./sprint-metrics.rb -b "Team Board" --since 2019-01-01 --until 2019-03-01
