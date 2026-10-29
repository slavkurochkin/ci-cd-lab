# prod. The only file in this directory that differs from the others,
# apart from the backend key in versions.tf.

environment = "prod"

# api 0.2.3, linux/amd64 manifest. Not the index digest (sha256:6201382c...):
# Lambda rejects an image index. To deploy a new release, change this line.
api_image_digest = "sha256:b3af8458ebb6c9748be00d87cff0e4bfcb0fbaba45d54ff2ce514adf5232c553"

# A bad overwrite in prod tends to be found late.
data_noncurrent_days = 90
