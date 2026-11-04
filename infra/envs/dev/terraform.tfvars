# dev. The only file in this directory that differs from the others,
# apart from the backend key in versions.tf.

environment = "dev"

# api 0.2.3, linux/amd64 manifest. Not the index digest (sha256:6201382c...):
# Lambda rejects an image index. To deploy a new release, change this line.
api_image_digest = "sha256:9944a7461c0c01a898845200b48f704be3fe0557839d771249a31ccb01bfba12"

# Losing old dev versions costs little.
data_noncurrent_days = 7
