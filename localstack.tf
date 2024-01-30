terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.23.1"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "access_key"
  secret_key                  = "secret_key"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
  endpoints {
    lambda     = "http://localhost:4566"
    cloudwatch = "http://localhost:4566"
    iam        = "http://localhost:4566"
    s3         = "http://localhost:4566"
    sns        = "http://localhost:4566"
    sqs        = "http://localhost:4566"
  }
}

# S3

resource "aws_s3_bucket" "example" {
  bucket = "bucket-trail"

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}

# Adding S3 bucket as trigger to lambda and giving the permissions
resource "aws_s3_bucket_notification" "aws-lambda-trigger" {
  bucket = aws_s3_bucket.example.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.lambda-filter.arn
    events              = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]

  }
}

resource "aws_lambda_permission" "test" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_name
  principal     = "s3.amazonaws.com"
  source_arn    = "arn:aws:s3:::${aws_s3_bucket.example.id}"
}

# Lambda

variable "lambda_root" {
  type        = string
  description = "The relative path to the source of the lambda"
  default     = "./src"
}

variable "lambda_name" {
  type        = string
  description = "Name of lambda function"
  default     = "lambda-filter"
}

resource "null_resource" "install_dependencies" {
  provisioner "local-exec" {
    command = "rm -f -r ${var.lambda_root}/lambda/* && python3 -m pip install -r ${var.lambda_root}/requirements.txt -t ${var.lambda_root}/lambda/"
  }

  triggers = {
    dependencies_versions = filemd5("${var.lambda_root}/requirements.txt")
    index_versions        = filemd5("${var.lambda_root}/index.py")
    filters_versions      = filemd5("${var.lambda_root}/filters.json")
  }
}

# to ensure that cached versions of the Lambda aren't invoked by AWS -> unique names for each version
resource "random_uuid" "lambda_src_hash" {
  keepers = {
    for filename in setunion(
      fileset(var.lambda_root, "requirements.txt"),
      fileset(var.lambda_root, "index.py"),
      fileset(var.lambda_root, "filters.json")
    ) :
    filename => filemd5("${var.lambda_root}/${filename}")
  }
}

resource "null_resource" "copy-main-files" {


  provisioner "local-exec" {
    command      = "cp ${var.lambda_root}/index.py ${var.lambda_root}/lambda/index.py"
  }

  provisioner "local-exec" {
    command      = "cp ${var.lambda_root}/filters.json ${var.lambda_root}/lambda/filters.json"
  }

  depends_on = [
    null_resource.install_dependencies
  ]
}

data "archive_file" "lambda_source" {

  excludes = [
    "__pycache__",
    "venv",
  ]

  source_dir  = "${var.lambda_root}/lambda/"
  output_path = "${var.lambda_root}/lambda/${random_uuid.lambda_src_hash.result}.zip"
  type        = "zip"
  depends_on = [
    null_resource.install_dependencies,
    null_resource.copy-main-files
  ]
}



resource "aws_iam_role" "lambda-role" {
  name               = "${var.lambda_name}-lambda"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_lambda_function" "lambda-filter" {
  filename         = data.archive_file.lambda_source.output_path
  source_code_hash = data.archive_file.lambda_source.output_base64sha256
  function_name    = var.lambda_name
  role             = aws_iam_role.lambda-role.arn
  handler          = "index.handler"
  runtime          = "python3.9"
  memory_size      = 512
  timeout          = 900
  environment {
    variables = {
      DESTINATION_BOOTSTRAP_SERVERS = "broker:29092"
      DESTINATION_TOPIC             = "mytopic"
      DESTINATION_GROUP_ID          = "mytopic"
      DEBUG                         = "True"
    }
  }
}

