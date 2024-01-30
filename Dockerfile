FROM public.ecr.aws/lambda/python:3.9

COPY src/ .

RUN pip install -r requirements.txt

RUN yum update -y libssh2
RUN yum install -y elfutils

CMD ["index.handler"]