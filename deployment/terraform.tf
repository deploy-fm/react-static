provider "aws" {
  region = "${var.region}"
}

data "aws_caller_identity" "current" {}

# Deployment Location
resource "aws_s3_bucket" "deployment_bucket" {
  bucket = "${var.pipeline_name}-${data.aws_caller_identity.current.account_id}-deploy"
  acl = "public-read"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadForGetBucketObjects",
      "Effect": "Allow",
      "Principal": {
        "AWS": "*"
      },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${var.pipeline_name}-${data.aws_caller_identity.current.account_id}-deploy/*"
    }
  ]
}
EOF

  website {
    index_document = "index.html"
    error_document = "index.html"
  }
}

# CodePipeLine Resources
resource "aws_s3_bucket" "build_artifact_bucket" {
  bucket = "${var.pipeline_name}-${data.aws_caller_identity.current.account_id}-artifact-bucket"
  acl = "private"
}

data "aws_iam_policy_document" "codepipeline_assume_policy" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline_role" {
  name = "${var.pipeline_name}-codepipeline-role"
  assume_role_policy = "${data.aws_iam_policy_document.codepipeline_assume_policy.json}"
}

resource "aws_iam_role_policy" "attach_codepipeline_policy" {
  name = "${var.pipeline_name}-codepipeline-policy"
  role = "${aws_iam_role.codepipeline_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Effect": "Allow",
      "Resource": [
        "${aws_s3_bucket.build_artifact_bucket.arn}/*",
        "${aws_s3_bucket.deployment_bucket.arn}",
        "${aws_s3_bucket.deployment_bucket.arn}/*"
      ]
    },
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "cloudwatch:PutMetricData"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "codepipeline:DeleteWebhook",
        "codepipeline:DeregisterWebhookWithThirdParty",
        "codepipeline:GetJobDetails",
        "codepipeline:GetPipeline",
        "codepipeline:GetPipelineExecution",
        "codepipeline:GetPipelineState",
        "codepipeline:GetThirdPartyJobDetails",
        "codepipeline:ListActionTypes",
        "codepipeline:ListPipelines",
        "codepipeline:ListWebhooks",
        "codepipeline:PutWebhook",
        "codepipeline:RegisterWebhookWithThirdParty"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "iam:PassRole"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_role" "codebuild_assume_role" {
  name = "${var.pipeline_name}-codebuild-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      }
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codebuild_policy" {
  name = "${var.pipeline_name}-codebuild-policy"
  role = "${aws_iam_role.codebuild_assume_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Effect": "Allow",
      "Resource": [
        "${aws_s3_bucket.build_artifact_bucket.arn}/*",
        "${aws_s3_bucket.deployment_bucket.arn}/*"
      ]
    },
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "cloudwatch:PutMetricData"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "codebuild:*"
      ],
      "Effect": "Allow",
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
}

# CodeBuild Section
resource "aws_codebuild_project" "build_project" {
  name = "${var.pipeline_name}-build"
  description = "The Codebuild Project for  ${var.pipeline_name}"
  service_role = "${aws_iam_role.codebuild_assume_role.arn}"
  build_timeout = "10"

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image = "aws/codebuild/nodejs:10.14.1"
    type = "LINUX_CONTAINER"

    environment_variable {
      "name" = "DEPLOY_S3_BUCKET"
      "value" = "${aws_s3_bucket.deployment_bucket.id}"
    }
  }

  source {
    type = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }
}

# CodePipeline
resource "aws_codepipeline" "codepipeline" {
  name = "${var.pipeline_name}-codepipeline"
  role_arn = "${aws_iam_role.codepipeline_role.arn}"

  artifact_store {
    location = "${aws_s3_bucket.build_artifact_bucket.id}"
    type = "S3"
  }

  stage {
    name = "Source"

    action {
      name = "GitHub"
      category = "Source"
      owner = "ThirdParty"
      provider = "GitHub"
      version = "1"
      output_artifacts = ["code"]

      configuration {
        Owner = "${var.github_org}"
        Repo = "${var.github_repo}"
        Branch = "master"
        OAuthToken = "${var.github_oauth_token}"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name = "CodeBuild"
      category = "Build"
      owner = "AWS"
      provider = "CodeBuild"
      input_artifacts = ["code"]
      output_artifacts = ["built"]
      version = "1"

      configuration {
        ProjectName = "${aws_codebuild_project.build_project.name}"
      }
    }
  }

  stage {
    name = "Staging"

    action {
      name = "DeployApplication"
      category = "Deploy"
      owner = "AWS"
      provider = "S3"
      input_artifacts = ["built"]
      version = "1"

      configuration {
        BucketName = "${aws_s3_bucket.deployment_bucket.id}"
        Extract = "true"
      }
    }
  }
}