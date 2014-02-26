FROM ubuntu:precise
RUN ( nc -zw 8 172.17.42.1 3142 && echo 'Acquire::http { Proxy "http://172.17.42.1:3142"; };' > /etc/apt/apt.conf.d/01proxy ) || true
RUN apt-get update
RUN apt-get install -y openjdk-7-jre-headless wget
RUN ( mkdir /root/elasticsearch && cd /root/elasticsearch && wget -O- 'https://download.elasticsearch.org/elasticsearch/elasticsearch/elasticsearch-1.0.1.tar.gz' | tar -xz --strip-components 1 )
EXPOSE 9200 9300
VOLUME /root/elasticsearch/data
ADD . /root
WORKDIR /root
ENTRYPOINT [ "./run" ]
