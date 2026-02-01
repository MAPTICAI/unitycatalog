package io.unitycatalog.server.service.credential.aws;

import lombok.Builder;
import lombok.Getter;
import lombok.ToString;

@Getter
@Builder
@ToString
public class S3StorageConfig {
  private final String bucketPath;
  private final String region;
  private final String awsRoleArn;
  private final String accessKey;
  private final String secretKey;
  private final String sessionToken;
  private final String credentialsGenerator;
  /** Optional custom endpoint for S3-compatible storage (e.g. MinIO). */
  private final String endpoint;
  /** Use path-style access (required for MinIO). Default false for AWS S3. */
  private final Boolean pathStyleAccess;
}
