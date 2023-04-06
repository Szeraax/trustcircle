CREATE TABLE [dbo].[Game]
(
  [Id] INT NOT NULL PRIMARY KEY IDENTITY,
  [StartTime] DATETIME2 DEFAULT (sysdatetime()),
  [EndTime] DATETIME2,
  [GuildId] VARCHAR(50),
  [LastReport] INT DEFAULT 0 NULL,
  [LastReportTime] DATETIME2,
  [InitiatorId] VARCHAR(50),
  [StatusWebhook] VARCHAR(MAX),
)

