provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

locals {
  name   = "ex-${basename(path.cwd)}"
  region = "us-east-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  connector_external_url = "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/2.3.0.Final/debezium-connector-postgres-2.3.0.Final-plugin.tar.gz"
  connector              = "debezium-connector-postgres/debezium-connector-postgres-2.3.0.Final.jar"

  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-msk-kafka-cluster"
    GithubOrg  = "terraform-aws-modules"
  }
}

################################################################################
# MSK Cluster
################################################################################

module "msk_cluster" {
  source = "../.."

  name                   = local.name
  kafka_version          = "3.4.0"
  number_of_broker_nodes = 3

  broker_node_client_subnets  = module.vpc.private_subnets
  broker_node_instance_type   = "kafka.t3.small"
  broker_node_security_groups = [module.security_group.security_group_id]

  # Connect custom plugin(s)
  connect_custom_plugins = {
    debezium = {
      name         = "debezium-postgresql"
      description  = "Debezium PostgreSQL connector"
      content_type = "JAR"

      s3_bucket_arn     = module.s3_bucket.s3_bucket_arn
      s3_file_key       = aws_s3_object.debezium_connector.id
      s3_object_version = aws_s3_object.debezium_connector.version_id

      timeouts = {
        create = "5m"
      }
    }
  }

  # Connect worker configuration
  create_connect_worker_configuration           = true
  connect_worker_config_name                    = local.name
  connect_worker_config_description             = "Example connect worker configuration"
  connect_worker_config_properties_file_content = <<-EOT
    key.converter=org.apache.kafka.connect.storage.StringConverter
    value.converter=org.apache.kafka.connect.storage.StringConverter
  EOT

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs              = local.azs
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 3)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 6)]

  create_database_subnet_group = true
  enable_nat_gateway           = true
  single_nat_gateway           = true

  tags = local.tags
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "Security group for ${local.name}"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = module.vpc.private_subnets_cidr_blocks
  ingress_rules = [
    "kafka-broker-tcp",
    "kafka-broker-tls-tcp"
  ]
  
  egress_rules = ["all-all"]

  tags = local.tags
}

module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 3.0"

  bucket_prefix = local.name
  acl           = "private"
  
  control_object_ownership = true
  object_ownership         = "ObjectWriter"

  versioning = {
    enabled = true
  }

  # Allow deletion of non-empty bucket for testing
  force_destroy = true

  attach_deny_insecure_transport_policy = true
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = local.tags
}

resource "aws_s3_object" "debezium_connector" {
  bucket = module.s3_bucket.s3_bucket_id
  key    = local.connector
  source = local.connector

  depends_on = [
    null_resource.debezium_connector
  ]
}

resource "null_resource" "debezium_connector" {
  provisioner "local-exec" {
    command = <<-EOT
      wget -c ${local.connector_external_url} -O connector.tar.gz \
        && tar -zxvf connector.tar.gz  ${local.connector} \
        && rm *.tar.gz
    EOT
  }
}

################################################################################
# IAM Role
################################################################################

module "iam_policy_kafka" {
  source = "terraform-aws-modules/iam/aws//modules/iam-policy"

  name        = "${local.name}_kafka"
  path        = "/"
  description = "My example policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:*Topic*",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData"
        ]
        Resource = module.msk_cluster.arn
      }
    ]
  })
}

module "iam_assumable_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"

  trusted_role_services = ["kafkaconnect.amazonaws.com"]

  create_role = true

  role_name         = local.name
  role_requires_mfa = false

  custom_role_policy_arns = [
    module.iam_policy_kafka.arn,
  ]
  number_of_custom_role_policy_arns = 1
}

################################################################################
# Connector
################################################################################

resource "aws_mskconnect_connector" "debezium_postgres" {
  name = local.name

  kafkaconnect_version = "2.7.1"

  capacity {
    provisioned_capacity {
      worker_count = 1
    }
  }

  connector_configuration = {
    "name"                                            = local.name
    "connector.class"                                 = "io.debezium.connector.postgresql.PostgresConnector"
    "tasks.max"                                       = 1
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = module.msk_cluster.bootstrap_brokers_tls

      vpc {
        security_groups = [module.security_group.security_group_id]
        subnets         = module.vpc.private_subnets
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "NONE"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = module.msk_cluster.connect_custom_plugins.debezium.arn
      revision = module.msk_cluster.connect_custom_plugins.debezium.latest_revision
    }
  }

  log_delivery {
    worker_log_delivery {
      s3 {
        enabled = true
        bucket  = module.s3_bucket.s3_bucket_id
      }
    }
  }

  service_execution_role_arn = module.iam_assumable_role.iam_role_arn
}