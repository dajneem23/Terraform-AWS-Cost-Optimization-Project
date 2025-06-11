# network.tf

# A VPC for our resources to live in.
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "cost-optimization-vpc"
  }
}

# A public subnet. The Auto Scaling Group will launch instances here.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true # Useful for connecting to instances if needed
  availability_zone       = "us-east-1a"

  tags = {
    Name = "cost-optimization-public-subnet"
  }
}

# An Internet Gateway to allow traffic to/from the internet.
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# A Route Table to direct traffic to the IGW.
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Associate the Route Table with our subnet.
resource "aws_route_table_association" "public_subnet_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}