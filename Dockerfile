FROM docker.elastic.co/elasticsearch/elasticsearch:7.9.1

# install default plugins and prepare AWS config dir (for S3 repository config)
RUN echo "y" | /usr/share/elasticsearch/bin/elasticsearch-plugin install repository-s3 \
    && echo "y" | /usr/share/elasticsearch/bin/elasticsearch-plugin install analysis-phonetic \
    && install -o elasticsearch -g root -d /usr/share/elasticsearch/.aws

# add custom scripts
COPY --chown=elasticsearch:root [ "scripts/start_elasticsearch.sh", "/usr/local/bin" ]

# update underlying OS
USER root
RUN yum clean all && yum update -y && yum clean all

# run as the elasticsearch user (1000:1000)
USER 1000

# run our custom start scrip as the entrypoint (allowing for user specified command/args)
ENTRYPOINT [ "/usr/local/bin/start_elasticsearch.sh" ]

# Dummy overridable parameter parsed by entrypoint

CMD [ "eswrapper" ]
