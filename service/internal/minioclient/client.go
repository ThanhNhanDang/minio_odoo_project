package minioclient

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// Client wraps the MinIO SDK client.
type Client struct {
	mc     *minio.Client
	bucket string
}

// ObjectInfo represents a file or folder in MinIO.
type ObjectInfo struct {
	Name         string `json:"name"`
	Type         string `json:"type"` // "file" or "folder"
	Size         int64  `json:"size"`
	LastModified string `json:"lastModified"`
	Path         string `json:"path"`
}

// New creates a connected MinIO client.
// endpoint can include protocol (http:// or https://) and trailing slash — they are stripped.
func New(endpoint, accessKey, secretKey, bucket string, secure bool) (*Client, error) {
	// Strip protocol prefix and auto-detect secure
	if strings.HasPrefix(endpoint, "https://") {
		endpoint = strings.TrimPrefix(endpoint, "https://")
		secure = true
	} else if strings.HasPrefix(endpoint, "http://") {
		endpoint = strings.TrimPrefix(endpoint, "http://")
		// Keep secure as-is (caller may have overridden)
	}
	endpoint = strings.TrimRight(endpoint, "/")

	mc, err := minio.New(endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(accessKey, secretKey, ""),
		Secure: secure,
		Region: "us-east-1",
	})
	if err != nil {
		return nil, fmt.Errorf("minio connect: %w", err)
	}
	return &Client{mc: mc, bucket: bucket}, nil
}

// EnsureBucket creates the bucket if it does not exist.
func (c *Client) EnsureBucket(ctx context.Context) error {
	exists, err := c.mc.BucketExists(ctx, c.bucket)
	if err != nil {
		return fmt.Errorf("bucket check: %w", err)
	}
	if !exists {
		return c.mc.MakeBucket(ctx, c.bucket, minio.MakeBucketOptions{Region: "us-east-1"})
	}
	return nil
}

// Upload puts a file into MinIO and returns the object path.
func (c *Client) Upload(ctx context.Context, objectName string, reader io.Reader, size int64, contentType string) error {
	opts := minio.PutObjectOptions{}
	if contentType != "" {
		opts.ContentType = contentType
	}
	_, err := c.mc.PutObject(ctx, c.bucket, objectName, reader, size, opts)
	if err != nil {
		return fmt.Errorf("upload %s: %w", objectName, err)
	}
	return nil
}

// ListObjects lists objects at a given prefix (non-recursive).
func (c *Client) ListObjects(ctx context.Context, prefix string) ([]ObjectInfo, error) {
	if prefix != "" && !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}

	opts := minio.ListObjectsOptions{
		Prefix:    prefix,
		Recursive: false,
	}

	var items []ObjectInfo
	for obj := range c.mc.ListObjects(ctx, c.bucket, opts) {
		if obj.Err != nil {
			return nil, fmt.Errorf("list: %w", obj.Err)
		}

		fullPath := strings.TrimSuffix(obj.Key, "/")
		name := strings.TrimPrefix(obj.Key, prefix)
		name = strings.TrimSuffix(name, "/")
		if name == "" {
			continue
		}

		item := ObjectInfo{
			Name: name,
			Path: fullPath,
			Size: obj.Size,
		}

		if strings.HasSuffix(obj.Key, "/") || obj.Size == 0 && strings.Contains(obj.Key[len(prefix):], "/") {
			item.Type = "folder"
		} else {
			item.Type = "file"
		}

		if !obj.LastModified.IsZero() {
			item.LastModified = obj.LastModified.Format("2006-01-02T15:04:05Z")
		}

		items = append(items, item)
	}
	return items, nil
}

// Delete removes a single object.
func (c *Client) Delete(ctx context.Context, objectName string) error {
	return c.mc.RemoveObject(ctx, c.bucket, objectName, minio.RemoveObjectOptions{})
}

// DeleteRecursive removes all objects under a prefix.
func (c *Client) DeleteRecursive(ctx context.Context, prefix string) error {
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}

	objectsCh := c.mc.ListObjects(ctx, c.bucket, minio.ListObjectsOptions{
		Prefix:    prefix,
		Recursive: true,
	})

	for obj := range objectsCh {
		if obj.Err != nil {
			return fmt.Errorf("list for delete: %w", obj.Err)
		}
		if err := c.mc.RemoveObject(ctx, c.bucket, obj.Key, minio.RemoveObjectOptions{}); err != nil {
			return fmt.Errorf("delete %s: %w", obj.Key, err)
		}
	}
	return nil
}

// GetObject returns a reader for the object content.
func (c *Client) GetObject(ctx context.Context, objectName string) (io.ReadCloser, int64, string, error) {
	obj, err := c.mc.GetObject(ctx, c.bucket, objectName, minio.GetObjectOptions{})
	if err != nil {
		return nil, 0, "", fmt.Errorf("get %s: %w", objectName, err)
	}

	stat, err := obj.Stat()
	if err != nil {
		obj.Close()
		return nil, 0, "", fmt.Errorf("stat %s: %w", objectName, err)
	}

	return obj, stat.Size, stat.ContentType, nil
}

// BucketName returns the configured bucket name.
func (c *Client) BucketName() string {
	return c.bucket
}

// Connected tests if the MinIO server is reachable.
func (c *Client) Connected(ctx context.Context) bool {
	_, err := c.mc.BucketExists(ctx, c.bucket)
	return err == nil
}
