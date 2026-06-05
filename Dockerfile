FROM ghcr.io/catthehacker/ubuntu:act-24.04
# 移除软链接，创建真实目录
RUN rm /var/run && mkdir -p /var/run && cp -R /run/* /var/run/ || true