output "cluster" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.sandbox.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.sandbox.repository_url
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "security_group_id" {
  value = aws_security_group.sandbox.id
}

output "subnet_ids" {
  value = data.aws_subnets.public.ids
}

output "smoke_task_definition" {
  value = aws_ecs_task_definition.smoke.arn
}
