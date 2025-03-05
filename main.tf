# Configure the AWS Provider to deploy resources in us-east-1 region
provider "aws" {
  region = "us-east-1"
}

# GitHub provider configuration
provider "github" {
  token = var.github_token
  owner = var.github_owner
}

# Variables for GitHub webhook
variable "github_token" {
  description = "GitHub personal access token"
  type        = string
  sensitive   = true
}

variable "github_owner" {
  description = "GitHub owner/organization name"
  type        = string
}

variable "github_repository" {
  description = "GitHub repository full name (owner/repo)"
  type        = string
  default     = "your-github-username/terraform-ecs"
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Create a VPC (Virtual Private Cloud) to host our ECS infrastructure
# CIDR block provides 65,536 IP addresses (10.0.0.0 - 10.0.255.255)
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Add after the VPC resource
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "Main IGW"
  }
}

# Add a route table for internet access
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"  
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "Main Route Table"
  }
}

# Associate the route table with the subnet
resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.subnet.id
  route_table_id = aws_route_table.main.id
}

# Create a Subnet within the VPC
# This subnet will have 256 IP addresses (10.0.1.0 - 10.0.1.255)
# Note: For production, you should have multiple subnets across different AZs
resource "aws_subnet" "subnet" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

# Create an ECS Cluster to group and manage our containers
# This is the logical grouping where ECS tasks and services will run
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "my-ecs-cluster"
}

# Define the ECS Task Definition
# This specifies how our container(s) should run
# Using Fargate launch type for serverless container management
resource "aws_ecs_task_definition" "task" {
  family                   = "my-task"          # Logical grouping of task definitions
  requires_compatibilities = ["FARGATE"]        # Use Fargate launch type
  network_mode             = "awsvpc"           # Required for Fargate
  cpu                      = "512"              # Increased to support both containers
  memory                   = "1024"             # Increased to support both containers
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  # Container definition specifies the Docker container configuration
  container_definitions = jsonencode([
    {
      name      = "frontend"
      image     = "${aws_ecr_repository.frontend.repository_url}:latest"
      cpu       = 256                           # CPU units for the container
      memory    = 512                           # Memory in MB for the container
      essential = true                          # Container must be running for task to be considered healthy
      portMappings = [
        {
          containerPort = 80                     # Port exposed by container
          hostPort      = 80                     # Port exposed on the host
        }
      ]
    },
    {
      name      = "backend"
      image     = "${aws_ecr_repository.backend.repository_url}:latest"
      cpu       = 256                           # CPU units for the container
      memory    = 512                           # Memory in MB for the container
      essential = true                          # Container must be running for task to be considered healthy
      portMappings = [
        {
          containerPort = 8080                   # Port exposed by container
          hostPort      = 8080                   # Port exposed on the host
        }
      ]
    }
  ])
}

# Create ECR repositories for storing our Docker images
resource "aws_ecr_repository" "frontend" {
  name = "frontend"
}

resource "aws_ecr_repository" "backend" {
  name = "backend"
}

# Add security group for the ECS tasks
resource "aws_security_group" "ecs_tasks" {
  name        = "ecs-tasks-sg"
  description = "Allow inbound traffic to ECS tasks"
  vpc_id      = aws_vpc.main.id

  # Allow HTTP traffic to the frontend
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow traffic to the backend API
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create an ECS Service to maintain and scale our tasks
# The service ensures the desired number of tasks are running
resource "aws_ecs_service" "ecs_service" {
  name            = "my-service"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  launch_type     = "FARGATE"                   # Use Fargate for serverless container management
  desired_count   = 1                           # Number of tasks to run

  # Network configuration for the tasks
  network_configuration {
    subnets          = [aws_subnet.subnet.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs_tasks.id]
  }
}

# Output to show if public IP is assigned
output "task_public_ip" {
  value = aws_ecs_service.ecs_service.network_configuration[0].assign_public_ip
}

# Create IAM role for ECS task execution
# This role is used by ECS to pull images and publish logs
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Attach the ECS task execution policy to the execution role
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Create IAM role for ECS tasks
# This role is used by the container applications for AWS API access
resource "aws_iam_role" "ecs_task_role" {
  name = "ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Create IAM role for CodePipeline
# This role allows CodePipeline to access needed AWS resources
resource "aws_iam_role" "codepipeline_role" {
  name = "codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
      }
    ]
  })
}

# Define permissions for CodePipeline
resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline-policy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",              # Access artifacts in S3
          "s3:GetObjectVersion",       # Access versioned artifacts
          "s3:GetBucketVersioning",    # Check bucket versioning
          "s3:PutObject",              # Store artifacts in S3
          "s3:PutObjectAcl",           # Set permissions on S3 objects
          "ecr:GetAuthorizationToken", # Authenticate with ECR
          "ecr:BatchCheckLayerAvailability", # Check layers in ECR
          "ecr:GetDownloadUrlForLayer",      # Get layer download URLs
          "ecr:BatchGetImage",               # Get images from ECR
          "ecr:PutImage",                    # Push images to ECR
          "ecs:UpdateService",               # Update ECS service
          "ecs:DescribeServices",            # Get info about ECS services
          "codebuild:BatchGetBuilds",        # Get information about builds
          "codebuild:StartBuild",            # Start CodeBuild builds
          "codestar-connections:UseConnection" # Use GitHub connection
        ]
        Resource = "*"
      }
    ]
  })
}

# Create IAM role for CodeBuild
resource "aws_iam_role" "codebuild_role" {
  name = "codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}

# CodeBuild policy
resource "aws_iam_role_policy" "codebuild_policy" {
  name = "codebuild-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetObjectVersion",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "*"
      }
    ]
  })
}

# S3 bucket to store pipeline artifacts
resource "aws_s3_bucket" "artifact_store" {
  bucket = "my-app-artifact-store-${data.aws_caller_identity.current.account_id}"
}

# Create a CodeStar connection to GitHub
resource "aws_codestarconnections_connection" "github" {
  name          = "github-connection"
  provider_type = "GitHub"
}

# Create CodeBuild project for building Docker images
resource "aws_codebuild_project" "docker_build" {
  name         = "docker-build"
  description  = "Builds Docker images for ECS"
  service_role = aws_iam_role.codebuild_role.arn  # IAM role for CodeBuild

  # Define artifact configuration
  artifacts {
    type = "CODEPIPELINE"  # Use artifacts from CodePipeline
  }

  # Build environment configuration
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"  # Compute resources size
    image                       = "aws/codebuild/standard:5.0"  # Docker image for build
    type                        = "LINUX_CONTAINER"  # Container type
    image_pull_credentials_type = "CODEBUILD"  # Use CodeBuild for credentials
    privileged_mode             = true  # Required for Docker builds

    # Environment variables available during build
    environment_variable {
      name  = "ECR_REPOSITORY_URL"
      value = aws_ecr_repository.backend.repository_url
    }

    environment_variable {
      name  = "BACKEND_ECR_REPOSITORY_URL"
      value = aws_ecr_repository.backend.repository_url
    }

    environment_variable {
      name  = "FRONTEND_ECR_REPOSITORY_URL"
      value = aws_ecr_repository.frontend.repository_url
    }
  }

  # Source configuration - rely on external buildspec.yml file
  source {
    type      = "CODEPIPELINE"  # Get source from CodePipeline
    buildspec = "buildspec.yml"  # Use external buildspec.yml from repository root
  }
}

# Define the CI/CD pipeline
resource "aws_codepipeline" "main" {
  name     = "ecs-deploy-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  # Configure artifact storage
  artifact_store {
    location = aws_s3_bucket.artifact_store.bucket
    type     = "S3"
  }

  # Source stage - Get code from GitHub
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = "awynne/terraform-ecs"
        BranchName       = "main"
      }
    }
  }

  # Build stage - Build and push Docker images
  stage {
    name = "Build"

    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.docker_build.name
      }
    }
  }

  # Deploy stage - Deploy to ECS
  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ClusterName = aws_ecs_cluster.ecs_cluster.name
        ServiceName = aws_ecs_service.ecs_service.name
      }
    }
  }
}

# Create a random token for webhook security
resource "random_string" "webhook_secret" {
  length  = 32
  special = false
}

# Create the webhook in AWS CodePipeline
resource "aws_codepipeline_webhook" "github_webhook" {
  name            = "github-webhook"
  authentication  = "GITHUB_HMAC"
  target_action   = "Source"
  target_pipeline = aws_codepipeline.main.name

  authentication_configuration {
    secret_token = random_string.webhook_secret.result
  }

  filter {
    json_path    = "$.ref"
    match_equals = "refs/heads/main"
  }
}

# Create the webhook in GitHub
resource "github_repository_webhook" "codepipeline_webhook" {
  repository = element(split("/", var.github_repository), 1)
  
  configuration {
    url          = aws_codepipeline_webhook.github_webhook.url
    content_type = "json"
    insecure_ssl = false
    secret       = random_string.webhook_secret.result
  }

  events = ["push"]
}

