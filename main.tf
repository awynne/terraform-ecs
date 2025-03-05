# Configure the AWS Provider to deploy resources in us-east-1 region
provider "aws" {
  region = "us-east-1"
}

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

# Add ECR repositories for both frontend and backend
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

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

output "task_public_ip" {
  value = aws_ecs_service.ecs_service.network_configuration[0].assign_public_ip
}

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

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

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
