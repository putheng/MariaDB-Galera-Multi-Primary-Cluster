CREATE DATABASE IF NOT EXISTS appdb;

USE appdb;

CREATE TABLE IF NOT EXISTS load_test (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  thread_id INT NOT NULL,
  iter_id BIGINT NOT NULL,
  token CHAR(36) NOT NULL,
  full_name VARCHAR(64) NOT NULL,
  email VARCHAR(128) NOT NULL,
  amount DECIMAL(12,2) NOT NULL,
  payload VARCHAR(255) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_token (token),
  KEY idx_thread (thread_id),
  KEY idx_created (created_at)
) ENGINE=InnoDB;
