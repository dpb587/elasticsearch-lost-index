Background: we're running elasticsearch on AWS EC2; we use EBS volumes for persistence (`elasticsearch/data` directory); we're using the cluster for logstash; we re-provision servers during the deploy, fully stopping/starting the cluster.

We initially were running elasticsearch on a couple nodes (`master:true, data:true`). We then added another node (`master:true, data:false`) and changed the existing nodes to `master:false, data:true`). Everything came up successfully. During our next full deployment we had significant issues: all the indices since our last deploy were missing from elasticsearch.

We learned that index metadata is apparently not stored alongside the data on the data nodes; master nodes keep track of that with the cluster state. It obviously surprised us and we learned to allocate a small persistent volume to the master node as well. We were able to recover most of the ghost indices by re-creating the index metadata followed by data node restarts.

A small portion of the data, however, was lost. Apparently, when an elasticsearch data node receives new data for an index it's not yet responsible for, it blindly writes its new files to persist the data. In our case, when the cluster came back online, logstash events/docs for the current day started streaming in again, elasticsearch didn't have the index metadata, it created a new one, the old, ghost index files were overwritten and its data started from scratch.


# Steps to Reproduce

Clone this repo...

    $ git clone https://github.com/dpb587/elasticsearch-lost-index.git
    $ cd elasticsearch-lost-index

Build the container...

    $ docker build -rm -t elasticsearch-lost-index .
    ...snip...

Make some data directories...

    $ mkdir /tmp/elasticsearch-lost-index--{data1,data2,master1}

Start up two separate nodes in two separate terminals; wait for green...

    $ docker run -P -v /tmp/elasticsearch-lost-index--data1:/root/elasticsearch/data elasticsearch-lost-index config-defaults.yml
    $ docker run -P -v /tmp/elasticsearch-lost-index--data2:/root/elasticsearch/data elasticsearch-lost-index config-defaults.yml
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_cluster/stats" | python -mjson.tool | grep "status"
        "status": "green",

Create some dummy data and see that it gets there...

    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/logstash-2014.02.03/example" -d '{ "custom" : "first" }'
    ...snip...
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/logstash-2014.02.03/example" -d '{ "custom" : "second" }'
    ...snip...
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_search" | python -mjson.tool | grep "_id" | wc -l
    2
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_stats" | python -mjson.tool | grep "logstash-"
            "logstash-2014.02.03": {

Stop the running containers with `Ctrl-C`. In their separate terminal windows, start 1 x master and 2 x data; wait for green...

    $ docker run -P -v /tmp/elasticsearch-lost-index--master1:/root/elasticsearch/data elasticsearch-lost-index config-master.yml
    $ docker run -P -v /tmp/elasticsearch-lost-index--data1:/root/elasticsearch/data elasticsearch-lost-index config-data.yml
    $ docker run -P -v /tmp/elasticsearch-lost-index--data2:/root/elasticsearch/data elasticsearch-lost-index config-data.yml
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_cluster/stats" | python -mjson.tool | grep "status"
        "status": "green",

Verify the old data...

    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_search" | python -mjson.tool | grep "_id" | wc -l
    2
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_stats" | python -mjson.tool | grep "logstash-"
            "logstash-2014.02.03": {

Create some more dummy data and see that it gets there...

    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/logstash-2014.02.10/example" -d '{ "custom" : "alpha" }'
    ...snip...
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/logstash-2014.02.10/example" -d '{ "custom" : "bravo" }'
    ...snip...
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_search" | python -mjson.tool | grep "_id" | wc -l
    4
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_stats" | python -mjson.tool | grep "logstash-"
            "logstash-2014.02.03": {
            "logstash-2014.02.10": {

Stop the running containers with `Ctrl-C`. Then trash the master data volume...

    $ rm -fr /tmp/elasticsearch-lost-index--master1/*

Restart all three with the same commands; wait for green...

    ...snip...
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_cluster/stats" | python -mjson.tool | grep "status"
        "status": "green",
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_stats" | python -mjson.tool | grep "logstash-"
            "logstash-2014.02.03": {

So `logstash-2014.02.03` exists since apparently the data node can provide the metadata itself (it has the metadata since it was previously a master with it), but `logstash-2014.02.10` is missing (it still exists on the filesystem)...

    $ ls -l /tmp/elasticsearch-lost-index--data1/elasticsearch/nodes/0/indices/
    total 8
    drwxr-xr-x 8 root root 4096 Feb 25 20:24 logstash-2014.02.03
    drwxr-xr-x 7 root root 4096 Feb 25 20:25 logstash-2014.02.10

Now create new docs for `logstash-2014.02.10`...

    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/logstash-2014.02.10/example" -d '{ "custom" : "mercury" }'
    ...snip...
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_search" | python -mjson.tool | grep "_id" | wc -l
    3
    $ curl -s "http://`docker port $(docker ps -n 1  --no-trunc -q) 9200`/_stats" | python -mjson.tool | grep "logstash-"
            "logstash-2014.02.03": {
            "logstash-2014.02.10": {

So `3` documents and the the data previously in `logstash-2014.02.10` is gone. This is much more easy to see when the index has more than a couple bytes - with GB+ indices, it's noticeable by a large jump in available disk when they get trashed.

Cleanup: stop all the containers with `Ctrl-C` and trash the data volumes...

    $ rm -fr /tmp/elasticsearch-lost-index--*
