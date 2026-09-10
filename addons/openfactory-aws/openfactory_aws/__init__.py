"""openfactory-aws: enables the AWS/Fargate remote box by declaring the
`box_runner.fargate` entry point. The runner code lives in the core package at
`openfactory.runtime.fargate.launcher` (a vendor path reached only through the entry
point); this package supplies the registration and the boto3 dependency."""
__version__ = "0.0.1"
