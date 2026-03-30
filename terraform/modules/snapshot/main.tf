resource "null_resource" "snapshot" {
  triggers = {
    instance_id = var.instance_id
    images      = var.container_images
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/create_snapshot.sh ${var.instance_id} ${var.aws_region} ${var.container_images} ${path.module}/snapshot_id.txt"
    interpreter = ["/bin/bash", "-c"]
  }
}

data "local_file" "snapshot_id" {
  depends_on = [null_resource.snapshot]
  filename   = "${path.module}/snapshot_id.txt"
}
