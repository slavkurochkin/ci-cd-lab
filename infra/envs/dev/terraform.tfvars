# dev. The only file in this directory that differs from the others,
# apart from the backend key in versions.tf.

environment = "dev"

# api 0.2.4, linux/amd64 manifest. Not the index digest (sha256:ebaa5464...):
# Lambda rejects an image index. To deploy a new release, change this line.
# Deploy releases only: a sha- image is deleted by the ECR lifecycle policy
# once 10 newer tagged images exist (it took 9944a746..., an f4129c1 build, and left both
# functions Inactive with ImageDeleted on 2026-11-04). Releases are kept (20).
api_image_digest = "sha256:fac2210d15601e68149ac47ae8a0f6d4192dd6620d2c92fbc99daefccbd591bb"

# Losing old dev versions costs little.
data_noncurrent_days = 7
