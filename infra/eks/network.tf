# Public subnets only, and no NAT gateway anywhere in this file.
#
# A NAT gateway is $32/month and bills whether or not a packet crosses it. The
# textbook EKS topology puts nodes in private subnets and routes their egress
# through one, which is correct for production and indefensible for a lab that
# exists for four hours at a time.
#
# The trade is real and worth naming: these nodes have public IPs. That is
# acceptable here because the security group allows no inbound traffic from the
# internet except what a LoadBalancer Service explicitly opens, and because the
# cluster does not outlive the session. It would not be acceptable in production.

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # EKS requires both

  tags = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = { Name = "${var.cluster_name}-igw" }
}

# Two AZs because EKS refuses to create a control plane with fewer.
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.lab.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true # without this, nodes cannot reach the API server

  tags = {
    Name = "${var.cluster_name}-public-${count.index}"

    # The AWS load balancer controller looks for this tag to decide where it is
    # allowed to place an ELB. Without it, a Service of type LoadBalancer stays
    # <pending> forever and the event log says almost nothing useful.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
