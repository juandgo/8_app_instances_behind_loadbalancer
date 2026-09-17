output "alb_dns_name" {
  type        = string
  description = "The public DNS name of the Application Load Balancer"
  value       = aws_lb.loadbalancer.dns_name
}