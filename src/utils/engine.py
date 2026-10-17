"""PySpark engine — single SparkSession factory for extraction jobs."""

import os

from pyspark.sql import SparkSession


def get_spark(app_name: str = "banking-pipeline") -> SparkSession:
    """Return a configured SparkSession, reusing one if already built."""
    spark = (
        SparkSession.builder.appName(app_name)
        .config("spark.sql.adaptive.enabled", "true")
        .config("spark.sql.adaptive.coalescePartitions.enabled", "true")
        .config("spark.driver.memory", os.environ.get("SPARK_DRIVER_MEMORY", "2g"))
        .config("spark.sql.shuffle.partitions", os.environ.get("SPARK_SHUFFLE_PARTITIONS", "4"))
        .config("spark.sql.sources.partitionOverwriteMode", "dynamic")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")
    return spark
